# -*- encoding: utf-8 -*-

Gem::Specification.new do |gem|
  gem.version       = "0.0.1"
  gem.authors       = [""]
  gem.email         = [""]
  gem.description   = %q{NCBO Annotator population and query code}
  gem.summary       = %q{}
  gem.homepage      = "https://github.com/ncbo/ncbo_annotator"

  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "ncbo_annotator"
  gem.require_paths = ["lib"]

  gem.add_dependency("ontologies_linked_data")
  gem.add_dependency("goo")
  gem.add_dependency("redis")
end
