# Changelog

## Unreleased

### 0.1.0 - Initial release

- Detect repeated logical ActiveForce queries by query shape, call stack, and client.
- Support block-scoped scans, nested scans, pausing, and fiber-local scan state.
- Return structured reports or emit warnings and N+1 errors.
- Provide opt-in RSpec 3.13 integration that preserves existing failures and skips.
- Document Rails request and ActiveJob scanning with fake data.
- Require Ruby 2.7+, ActiveForce 0.27.0+, and ActiveSupport 7 or 8.
