require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec)
task default: :spec

desc 'Check Ruby syntax and patch whitespace'
task :lint do
  (Dir['lib/**/*.rb', 'spec/**/*.rb', 'integration/*_spec.rb', '*.gemspec'] + ['Rakefile', 'integration/Gemfile']).each do |file|
    ruby '-c', file
  end
  sh 'git diff --check'
end
