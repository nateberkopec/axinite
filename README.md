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

Authorized collaborators can install Axinite from the private repository with
`gem 'axinite', git: 'https://github.com/nateberkopec/axinite.git'`. GitHub access
is required. The instrumented dependency is available at
[ActiveForce commit `fea7929`](https://github.com/nateberkopec/active_force/commit/fea7929a103004b5817ccded56d82adc9e57b9cb)
in the [public independent copy](https://github.com/nateberkopec/active_force) of
Beyond-Finance/active_force, with preserved MIT license and history. Its
[instrumentation PR](https://github.com/nateberkopec/active_force/pull/1) targets
that personal repository, not upstream.

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
`finish` returns report hashes (`queries`, `stack`, `client_id`, `fingerprint`, `duration_ms`) and
clears state, even when paused. When using imperative scans, arrange cleanup in
your own ensure; prefer block form for original-exception preservation.

### Development requests and jobs

Keep the gem in the development/test Gemfile group above. Configure it explicitly
in `config/environments/development.rb` (not an unconditional initializer):

```ruby
require 'axinite'
Axinite.rails_logger = true # raw SOQL and local paths; fake data only
Axinite.raise = false
```

Wrap executed controller work in `app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::Base
  if Rails.env.development?
    around_action do |_controller, action|
      Axinite.scan { action.call }
    end
  end
end
```

For ActiveJob, wrap execution in `app/jobs/application_job.rb`:

```ruby
class ApplicationJob < ActiveJob::Base
  if Rails.env.development?
    around_perform do |_job, perform|
      Axinite.scan { perform.call }
    end
  end
end
```

The environment guards keep production boot independent of the development-only
gem. Loading/configuration alone never starts a scan. These block boundaries retain
nested-session ownership and original exceptions. They cover work actually executed
inside the block, not later streaming, lazy result materialization, or work in
unrelated fibers/threads. Job workers must run in the development environment too.
No Rails or Sidekiq runtime dependency or dedicated middleware is included.

### Explicit RSpec integration

Requiring the integration alone does nothing. Enable it once in `spec_helper.rb`
**before defining any example groups**. Installation does not update groups that
already exist; late installation is unsupported:

```ruby
require 'axinite/rspec'
Axinite.raise = true
RSpec.configure do |config|
  Axinite::RSpec.install!(config) # every example
  # OR: Axinite::RSpec.install!(config, metadata: :axinite)
end
```

With the metadata option, use `it 'loads contacts', :axinite do ... end`.
The optional integration supports **rspec-core 3.13.x** and rejects other versions
at installation. It uses one private hook-registration interface because public
`around` hooks run inside RSpec's built-in failure aggregation. Recheck this
compatibility boundary before upgrading RSpec; Axinite itself does not depend on RSpec.

Observed example failures, pending outcomes and runtime skips take precedence over
N+1 reporting, including aggregated expectations and before/after hooks. The scan
encloses ordinary user `around` hooks registered before or after installation.
Errors outside or after Axinite's owned scan (for example, suite teardown or an
externally wrapping integration) cannot be predicted or suppressed by Axinite.

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
  structure are retained. Currency-prefixed numbers normalize on comparison RHS
  and in complete currency-only `IN` lists. Same-currency lists collapse in size;
  mixed-currency lists retain their currency sequence. Mixed currency/plain-number
  lists are not normalized as currency lists. This is a query-shape heuristic, not a SOQL validator
  or semantic equivalence engine. Structurally different queries stay separate.
* `duration_ms` sums monotonic elapsed milliseconds for instrumented logical query
  execution in that exact full-stack/fingerprint/client group. Text reports label
  this as `ms elapsed query time`. It is not Salesforce server time, API call count,
  or total lazy pagination/materialization time. Failed and ignored events
  contribute neither groups nor timing.
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
not proof from an existing application. Local checks passed on actual Ruby 2.7.8
with AS/AM 7.0 and Restforce 5.3, and Ruby 3.3.11 with AS/AM 8.1 and Restforce 8.
These runtime receipts are distinct from remote CI. CI defines Ruby 2.7/ActiveSupport 7.0 and
Ruby 3.3/ActiveSupport 8.1 lanes. The opt-in cross-repository suite exercises actual
instrumented ActiveForce with fake clients, including association N+1 examples
and their `includes` equivalents. Query execution uses fake clients, not HTTP.
Loading ActiveForce still constructs its default Restforce client and can read
`SALESFORCE_*` configuration; clear those variables before loading in an isolated
fake-data run:

```fish
# Remove inherited Salesforce configuration without displaying values.
for name in (set --names --export | string match 'SALESFORCE_*')
    set --erase $name
end
# Point to the local ActiveForce checkout containing query.active_force.
set -lx ACTIVE_FORCE_PATH /path/to/active_force
set -lx BUNDLE_GEMFILE integration/Gemfile
bundle install
bundle exec rspec spec integration/active_force_spec.rb
# On Ruby 2.7, select the legacy AS/AM 7.0 + Restforce 5.3 lane:
set -lx LEGACY 1
bundle update
bundle exec rspec spec integration/active_force_spec.rb
```

CI also defines cross-repository integration jobs for Ruby 2.7 / AS-AM 7.0 /
Restforce 5.3 and Ruby 3.3 / AS-AM 8.1 / Restforce 8. The workflow pins fetchable
ActiveForce commit `fea7929a103004b5817ccded56d82adc9e57b9cb` from the public
independent copy `nateberkopec/active_force` (not a GitHub fork-network member).

Integration dependencies are test-only, not gem runtime dependencies. The
integration lockfile is local and ignored; use separate checkouts or re-resolve
when switching lanes. Synthetic examples are not genuine existing-application
regression proof. Genuine existing-business-application validation remains a
separate, incomplete delivery gate.

### Real Rails acceptance app

The small [acceptance app](acceptance/config/application.rb) boots genuine Rails
middleware, routes, controller callbacks, rendering and ActiveJob. It uses real
ActiveForce models and Restforce serialization/parsing; WebMock intercepts only
Salesforce HTTP and disables all network connections. All records, OAuth tokens
and hosts are synthetic. Boot removes inherited `SALESFORCE_*` names without
reading or displaying their values.

```sh
export ACTIVE_FORCE_PATH="$PWD/../upstream/active_force"
export BUNDLE_GEMFILE=acceptance/Gemfile
# Ruby 3.3.11: Rails/AS/AM 8.1.3.1, Restforce 8.0.1
bundle install
bundle exec rake acceptance
# Actual Ruby 2.7.8 with Bundler 2.4.22: Rails/AS/AM 7.0.10, Restforce 5.3.1
LEGACY=1 mise exec ruby@2.7.8 -- bundle _2.4.22_ update
LEGACY=1 mise exec ruby@2.7.8 -- bundle _2.4.22_ exec rake acceptance
# Re-resolve when returning to the modern lane (unset LEGACY).
bundle update
```

The acceptance-only Gemfile adds railties, actionpack and activejob, not the Rails
meta-gem, ActiveRecord, a database, assets or a server. It pins the two framework
lanes and RSpec 3.13.x, with WebMock 3.26.x. JSON is constrained below 3 because
Restforce 8.0.1's response middleware passes parser options as a positional hash;
JSON 3 removed that calling convention. No runtime gem dependencies change.

Coverage includes lazy/fixed `has_many`, `has_one` and `belongs_to`, explicit
lookup/count/sum loops and bulk equivalents, actual raising and original errors,
successive request/job isolation, composite batch bodies and JSON responses,
`nextRecordsUrl` pagination, detector sensitivity and explicit suite/metadata
RSpec opt-in in bounded Rails subprocesses. Assertions require real results,
HTTP and notification counts, raw warning queries, callsites and elapsed timing.
Only the two owned `*_spec.rb` entry points run; never run recursive spec discovery
or lint over `acceptance/`, which may contain installed dependencies.

Test/development environment files explicitly load/configure Axinite; callbacks
are guarded for those environments. A production subprocess boots with the
development/test gem groups excluded and verifies that Axinite is unavailable
to Bundler and its detector is not loaded.
Callbacks cover synchronous executed work, not streaming, later lazy
materialization or unrelated fibers. The count/sum bulk examples combine the two
per-owner totals into one aggregate. This is an automated real-Rails fixture with
HTTP-stubbed synthetic data, **not existing-business-application regression proof**.

Enabled acceptance CI uses the same immutable ActiveForce pin as integration.
[CI run 34313101624, attempt 2](https://github.com/nateberkopec/axinite/actions/runs/34313101624/attempts/2)
passed all six jobs at Axinite commit `f0a18c0d4b96aca908afd08ce670abb48e59ad0a`:
each Ruby lane ran 31 acceptance, 112 unit and 132 combined integration examples,
with zero failures; lint and package checks passed. No examples were replaced by
skipped/fallback jobs. Rails dependencies, generated logs, temporary files,
lockfiles and this app are excluded from the gem package.

## Contributing

Keep changes ActiveForce-specific and include fake-data regression tests. Run the
tests and syntax checks before submitting a change. Do not include credentials,
real Salesforce records, or raw private query reports.

## License

[Apache-2.0](LICENSE.txt). Prosopite's lifecycle API and grouping approach informed
this implementation and its behavioral tests; see [NOTICE](NOTICE) for attribution
and modifications. The separate ActiveForce instrumentation patch remains MIT.
