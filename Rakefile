# frozen_string_literal: true

require "rake/testtask"

require_relative "lib/cyborg/database"

Rake::TestTask.new(:test) do |test|
  test.libs << "lib" << "test"
  test.pattern = "test/**/*_test.rb"
end

task default: :test

namespace :db do
  desc "Apply timestamped SQLite migrations"
  task :migrate do
    path = ENV.fetch("CYBORG_DATABASE", File.expand_path("cyborg.sqlite3", __dir__))
    db = Cyborg::Database.connect(path: path)
    begin
      db.migrate!
    ensure
      db.disconnect
    end
  end
end
