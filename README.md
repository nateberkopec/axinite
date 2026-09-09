# Axinite

Find N+1 queries made through **ActiveForce**, using fake data in local development
and tests. Axinite reports repeated SOQL shapes from the same complete call stack
and client, including identical repeated queries. It does not depend on
ActiveRecord, Prosopite, or `pg_query`.

## Installation

This unreleased gem requires Ruby 2.7+ and ActiveSupport 7 or 8. It also requires
an ActiveForce version with the `query.active_force` instrumentation patch;
unpatched ActiveForce emits no events and **cannot be scanned**. No published
ActiveForce version is currently claimed to include that patch.

For local development, add your local checkouts to your application's Gemfile
(paths are examples, not committed dependency settings):

```ruby
group :development, :test do
  gem 'active_force', path: '../active_force'
  gem 'axinite', path: '../axinite'
end
```

Then run `bundle install`. Use only authorized local fake-data environments.

## Usage

```ruby
require 'axinite'
Axinite.raise = true # opt in to raw-query exceptions

Axinite.scan do
  # Run the code under test, using a fake ActiveForce client.
end
```

Requiring Axinite does not start scanning. `scan { ... }` returns the block value,
finishes its own session, and cleans up even when reporting fails. Original block
exceptions are preserved, without reporting a second N+1 exception. Nested scans
join the outer session and do not finish it. State is isolated per thread/fiber.

For non-block use, call `Axinite.scan`, execute code, then `Axinite.finish`.
`finish` returns report hashes (`queries`, `stack`, `client_id`, `fingerprint`) and
clears state, even when paused. When using imperative scans, arrange cleanup in
your own ensure; prefer block form for original-exception preservation.

### Explicit RSpec integration

Requiring the integration alone does nothing. Enable it once in `spec_helper.rb`:

```ruby
require 'axinite/rspec'
Axinite.raise = true
RSpec.configure do |config|
  Axinite::RSpec.install!(config) # every example
  # OR: Axinite::RSpec.install!(config, metadata: :axinite)
end
```

With the metadata option, use `it 'loads contacts', :axinite do ... end`.
Existing example failures take precedence over N+1 reporting.

### Configuration

```ruby
Axinite.min_n_queries = 2 # default; also Axinite.threshold=
Axinite.ignore_queries = [/FROM Audit__c/] # SOQL string or pattern matches
Axinite.allow_stack_paths = [/spec\/support\/intentional_queries\.rb/]
Axinite.custom_logger = Logger.new($stderr) # opt in; receives #warn
Axinite.stderr_logger = true
# Axinite.rails_logger = true              # only when Rails is available
# Axinite.axinite_logger = 'log/axinite.log' # explicit writable file path
# Axinite.backtrace_cleaner = Rails.backtrace_cleaner
Axinite.enabled = false # global switch; enabled? / disabled?
```

All output destinations and raising are off by default. Reports contain **raw
SOQL**, including literals, and local paths. Opting into loggers, exceptions, or
consuming `finish` reports is a deliberate raw-data choice. Do not use production
credentials/data, upload sensitive reports, or run this in production.

`pause { ... }` restores the previous pause state and preserves returns/exceptions.
`pause` / `resume` also work within an existing scan. `resume` never creates a
session. `ignore_pauses = true` makes pauses ineffective. `start_raise` /
`stop_raise` control fiber-local raising; `raise = true` enables it globally.

## Features and limitations

* A group is the exact **full path/line stack sequence + SOQL fingerprint + client
  identity**. Stack cleaning affects display only. No default stack ignores or
  blanket batching exemptions are applied. Threshold is an integer of at least 2.
* The lexer normalizes escaped strings, numeric/date/datetime/relative-date
  literals and literal `IN` lists. Digits inside names and relationship subquery
  structure are retained. This is a query-shape heuristic, not a SOQL validator
  or semantic equivalence engine. Structurally different queries stay separate.
* Counts are **logical ActiveForce executions, not Salesforce API requests**.
  Restforce HTTP-cache hits still count; the event has no public cache-hit marker.
  Retries and later pagination do not add events. Lazy construction and loaded
  memoized relations do not execute again. The detector never enumerates results.
* ActiveForce result/count/sum queries are covered, including composite batching;
  failed notifications are excluded. Direct Restforce, SOSL, writes, Bulk APIs,
  and other adapters are out of scope. No automatic fixes are made.
* The event payload is `soql` (String), `model` (SObject class), `client_id`
  (nonsecret identity), and `transport` (`:query` or `:composite_batch`), plus
  standard ActiveSupport exception fields on failure.
* Full-stack matching is intentionally strict and can miss equivalent loops with
  different caller paths. Long scans retain raw queries/stacks in memory: keep
  scans bounded to examples or small operations. Configuration is process-wide;
  do not mutate configuration concurrently. Sessions are fiber-local.

## Development and testing

```sh
bundle install
bundle exec rake
bundle exec rake lint
gem build axinite.gemspec
```

The unit suite uses synthetic notification payloads and fake strings only. It is
not proof from an existing application. CI defines Ruby 2.7/ActiveSupport 7.0 and
Ruby 3.3/ActiveSupport 8.1 lanes. Cross-repository ActiveForce integration and
real-application regression validation are separate delivery gates; no green
remote CI or real-app result is claimed by this initial scaffold.

## Contributing

Keep changes ActiveForce-specific and include fake-data regression tests. Run the
tests and syntax checks before submitting a change. Do not include credentials,
real Salesforce records, or raw private query reports.

## License

[Apache-2.0](LICENSE.txt). Prosopite's lifecycle API and grouping approach informed
this implementation and its behavioral tests; see [NOTICE](NOTICE) for attribution
and modifications. The separate ActiveForce instrumentation patch remains MIT.
