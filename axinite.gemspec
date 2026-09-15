require_relative 'lib/axinite/version'
Gem::Specification.new do |spec|
  spec.name = 'axinite'
  spec.version = Axinite::VERSION
  spec.summary = 'Detect repeated logical ActiveForce queries in development and tests'
  spec.authors = ['Nate Berkopec']
  spec.license = 'Apache-2.0'
  spec.homepage = 'https://github.com/nateberkopec/axinite'
  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md"
  }
  spec.required_ruby_version = '>= 2.7'
  spec.files = Dir['lib/**/*.rb', 'README.md', 'CHANGELOG.md', 'LICENSE.txt', 'NOTICE']
  spec.require_paths = ['lib']
  spec.add_dependency 'active_force', '>= 0.27.0'
  spec.add_dependency 'activesupport', '>= 7.0', '< 9'
end
