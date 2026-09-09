require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec)
task default: :spec

desc 'Run the real Rails acceptance suite (use BUNDLE_GEMFILE=acceptance/Gemfile)'
RSpec::Core::RakeTask.new(:acceptance) do |task|
  task.pattern = ['acceptance/rails_spec.rb', 'acceptance/rspec_spec.rb']
end

desc 'Check Ruby syntax and patch whitespace'
task :lint do
  (Dir['lib/**/*.rb', 'spec/**/*.rb', 'integration/*_spec.rb', 'acceptance/*_spec.rb',
       'acceptance/support.rb', 'acceptance/rspec_fixture.rb',
       'acceptance/app/**/*.rb', 'acceptance/config/**/*.rb', '*.gemspec'] +
    ['Rakefile', 'integration/Gemfile', 'acceptance/Gemfile']).each do |file|
    ruby '-c', file
  end
  sh 'git diff --check'
end
