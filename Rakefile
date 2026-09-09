require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec)
task default: :spec

desc 'Check Ruby syntax and patch whitespace'
task :lint do
  (Dir['lib/**/*.rb', 'spec/**/*.rb', '*.gemspec'] + ['Rakefile']).each do |file|
    ruby '-c', file
  end
  sh 'git diff --check'
end
