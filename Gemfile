source 'https://rubygems.org'

gem 'rake'
gem 'pry'
gem 'redis'
gem 'sparql-client', :git => 'https://github.com/ncbo/sparql-client.git'

# NCBO gems (can be from a local dev path or from rubygems/git)
gemfile_local = File.expand_path("../Gemfile.local", __FILE__)
if File.exists?(gemfile_local)
  self.instance_eval(Bundler.read_file(gemfile_local))
else
  gem 'goo', :git => 'https://github.com/ncbo/goo.git'
  gem 'ontologies_linked_data', :git => 'https://github.com/ncbo/ontologies_linked_data.git'
end
