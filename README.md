# Axinite

Find N+1 queries in Ruby apps that use **ActiveForce**. Axinite spots repeated
Salesforce queries so you can find loops that load records one at a time.

Use it with fake data in local development and tests. It can raise an error,
write a warning, or return a report. It does not need ActiveRecord, Prosopite,
or `pg_query`.

> [!WARNING]
> Use fake data only. Reports include raw SOQL, query values, and local file paths.
> Do not use Axinite in production, connect it to real Salesforce data, or share
> reports that contain private data.

## Installation

Axinite is not yet released on RubyGems. It requires Ruby 2.7+ and ActiveSupport
7 or 8. Your Ruby version must also support the ActiveSupport version you choose.

> [!IMPORTANT]
> Axinite needs ActiveForce to emit `query.active_force` events. An unpatched
> version cannot be scanned. Use the pinned version below; no published
> ActiveForce release is currently confirmed to include this patch.

Add these entries to your application's `Gemfile`. If you already list
ActiveForce, replace that entry rather than adding a second one.

```ruby
group :development, :test do
  gem 'active_force',
      git: 'https://github.com/nateberkopec/active_force.git',
      ref: 'fea7929a103004b5817ccded56d82adc9e57b9cb'
  gem 'axinite', git: 'https://github.com/nateberkopec/axinite.git'
end
```

Then install the gems:

```fish
bundle install
```

The ActiveForce pin comes from a [public copy](https://github.com/nateberkopec/active_force)
of Beyond-Finance/active_force. It keeps the original history and MIT license.
The [instrumentation PR](https://github.com/nateberkopec/active_force/pull/1)
targets that copy, not upstream.

Keep your normal ActiveForce setup available in any other environments that need
it. Keep Axinite itself in the development and test groups.

## Quickstart

In a local test that already uses a fake ActiveForce client, wrap the code you
want to check:

```ruby
require 'axinite'

Axinite.raise = true

Axinite.scan do
  # Run application code that queries through your fake ActiveForce client.
end
```

By default, two queries with the same query shape, full call stack, and client
trigger a report. Identical repeated queries count too. With `Axinite.raise`
enabled, a match raises `Axinite::NPlusOneQueriesError`.

Loading the gem does not start a scan. Log output and errors are off by default.

The block form returns your code's result and clears the scan state when it ends.
If your code raises an error, Axinite preserves that error instead of raising a
second one. Nested scans share the outer scan. Each fiber has its own scan state.

## Usage

### Check Rails requests and jobs

In `config/environments/development.rb`, enable warnings:

```ruby
require 'axinite'

Axinite.rails_logger = true
Axinite.raise = false
```

Wrap controller actions in `app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::Base
  if Rails.env.development?
    around_action do |_controller, action|
      Axinite.scan { action.call }
    end
  end
end
```

Wrap job execution in `app/jobs/application_job.rb`:

```ruby
class ApplicationJob < ActiveJob::Base
  if Rails.env.development?
    around_perform do |_job, perform|
      Axinite.scan { perform.call }
    end
  end
end
```

These guards keep production from loading Axinite. Job workers must also run in
the development environment. Do not put this setup in an initializer that runs
in every environment.

Scans cover only work that runs inside the block. They do not cover later
streaming, deferred query results, or work in other threads or fibers. Axinite
does not include Rails or Sidekiq middleware.

### Check RSpec examples

Add this to `spec_helper.rb` **before any example groups are defined**:

```ruby
require 'axinite/rspec'

Axinite.raise = true

RSpec.configure do |config|
  Axinite::RSpec.install!(config)
end
```

To scan only tagged examples, use this install call instead:

```ruby
Axinite::RSpec.install!(config, metadata: :axinite)
```

Then tag an example with `it 'loads contacts', :axinite do ... end`.
Run your application's specs as usual:

```fish
bundle exec rspec
```

The integration supports **rspec-core 3.13.x** and rejects other versions.
It uses a private RSpec hook, so check compatibility before upgrading RSpec.
Axinite does not otherwise depend on RSpec.

Existing failures, pending examples, and runtime skips take priority over N+1
errors. This includes failures from grouped expectations and before/after hooks.
The scan wraps normal user `around` hooks, but cannot handle errors outside its
scope, such as suite teardown. Installing it does not change groups that already
exist.

### Read reports directly

Prefer the block form for most uses. To read report hashes, start and finish a
scan yourself:

```ruby
Axinite.scan
begin
  # Run application code with a fake ActiveForce client.
ensure
  reports = Axinite.finish
end
```

`finish` returns one hash per matching group, with these keys:

| Key | Contents |
| --- | --- |
| `queries` | Raw SOQL strings |
| `stack` | Call stack |
| `client_id` | Client identity |
| `fingerprint` | Normalized query shape |
| `duration_ms` | Total elapsed query time for the group |

`finish` clears the scan state, even if the scan is paused. Enabled loggers and
errors still apply. Unlike the block form, an error from `finish` in an `ensure`
can replace an error from your code.

## Configuration

Set options before running scans. Configuration is process-wide; do not change
it from concurrent threads or fibers.

```ruby
Axinite.min_n_queries = 2 # Default; must be an integer of at least 2
Axinite.ignore_queries = [/FROM Audit__c/]
Axinite.allow_stack_paths = [/spec\/support\/intentional_queries\.rb/]
Axinite.stderr_logger = true
```

`ignore_queries` skips matching SOQL strings. `allow_stack_paths` skips queries
whose call stack contains a matching path. Both lists are empty by default.
`Axinite.threshold = 2` is an alias for `min_n_queries=`.

Choose other output options as needed:

```ruby
Axinite.custom_logger = Logger.new($stderr) # Receives #warn calls
Axinite.rails_logger = true                # Requires Rails
Axinite.axinite_logger = 'log/axinite.log'  # Requires a writable path
Axinite.backtrace_cleaner = Rails.backtrace_cleaner # Requires Rails
```

Stack cleaning changes the display, not query grouping.

To skip part of a scan:

```ruby
Axinite.pause do
  # Queries here do not count.
end
```

The block restores the prior pause state and preserves return values and errors.
You can also call `Axinite.pause` and `Axinite.resume` within a scan. `resume`
does not start a new scan. Set `Axinite.ignore_pauses = true` to count paused work.

Other controls:

- `Axinite.enabled = false` disables scanning. Check it with `enabled?` or `disabled?`.
- `Axinite.raise = true` enables N+1 errors globally.
- `Axinite.start_raise` and `Axinite.stop_raise` control the fiber-local error flag.
  `stop_raise` does not override the global flag.

## How detection works

Axinite groups queries by three exact matches:

1. Full call stack, including file paths and line numbers.
2. SOQL fingerprint, which describes the query's shape.
3. ActiveForce client identity.

The fingerprint normalizes literal values, such as strings, numbers, dates,
and literal `IN` lists. It keeps digits in field names and the structure of
relationship subqueries. Currency values are normalized in comparisons and
currency-only lists. Lists with one currency collapse to one shape; lists with
mixed currencies keep their currency order. Mixed currency/plain-number lists
do not use these currency rules.

This is a pattern check, not a SOQL validator. Queries with different structures
stay separate. Exact stack matching can miss similar loops reached through
different caller paths. There are no default stack exclusions or blanket
exceptions for batched queries.

### Scope and limits

- **Counts are ActiveForce executions, not Salesforce API requests.** Restforce
  HTTP-cache hits still count. Retries and later pages do not add events.
- Result, count, and sum queries are covered, including composite batches.
  Failed queries and ignored events do not count or add elapsed time.
- Direct Restforce calls, SOSL, writes, Bulk APIs, and other adapters are not covered.
- Creating a lazy query does not execute it. Reading an already loaded, memoized
  relation does not execute it again. Axinite never loads results itself.
- `duration_ms` measures elapsed time for the recorded query executions. It is
  not Salesforce server time or the total time to load later pages and results.
- Scans keep raw queries and stacks in memory. Keep them short: use one example,
  request, job, or small operation per scan.
- Axinite reports possible N+1 queries. It does not fix them.

## Contributing

Keep changes focused on ActiveForce and add regression tests with fake data.
Run tests and syntax checks before submitting a pull request. Do not include
credentials, real Salesforce records, or private query reports.

## License

[Apache-2.0](LICENSE.txt). Prosopite inspired the scan lifecycle, query grouping,
and related tests. See [NOTICE](NOTICE) for attribution and changes.
The separate ActiveForce instrumentation patch remains MIT-licensed.
