require 'rake/testtask'

Rake::TestTask.new do |t|
  t.libs = []
  t.test_files = FileList['test/**/test*.rb']
end

# EX: Adding sub-tasks to rake
# Rake::TestTask.new do |t|
#   t.libs = []
#   t.name = "test:models"
#   t.test_files = FileList['test/models/test*.rb']
# end

