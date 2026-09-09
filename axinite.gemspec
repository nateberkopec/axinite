require_relative 'lib/axinite/version'
Gem::Specification.new do |spec|
  spec.name = 'axinite'
  spec.version = Axinite::VERSION
  spec.summary = 'Detect repeated logical ActiveForce queries in development and tests'
  spec.authors = ['Nate Berkopec']
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 2.7'
  spec.files = Dir['lib/**/*.rb', 'README.md', 'LICENSE.txt', 'NOTICE']
  spec.require_paths = ['lib']
  spec.add_dependency 'activesupport', '>= 7.0', '< 9'
end
