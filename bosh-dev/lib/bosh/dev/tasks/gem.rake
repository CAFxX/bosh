require 'bosh/dev/gem_components'

COMPONENTS = Bosh::Dev::GemComponents.new
COMPONENTS.each do |component|
  namespace component do
    gem     = "pkg/gems/#{component}-#{COMPONENTS.version}.gem"
    gemspec = "#{component}.gemspec"

    task :update_version_rb do
      glob = File.join(COMPONENTS.root, component, "lib", "**", "version.rb")

      version_file_path = Dir[glob].first
      file_contents = File.read(version_file_path)

      file_contents.gsub!(/^(\s*)VERSION = (.*?)$/, "\\1VERSION = '#{COMPONENTS.version}'")
      read_version = $2.gsub(/\A['"]|['"]\Z/, '') # remove only leading and trailing single or double quote

      File.open(version_file_path, 'w') { |f| f.write file_contents } unless read_version == COMPONENTS.version
    end

    task :pre_stage_latest => [:update_version_rb, :pkg] do
      if COMPONENTS.component_needs_update(component, COMPONENTS.root, COMPONENTS.version)
        sh "cd #{component} && gem build #{gemspec} && mv #{component}-#{COMPONENTS.version}.gem #{COMPONENTS.root}/pkg/gems/"
      else
        sh "cp '#{COMPONENTS.last_released_component(component, COMPONENTS.root, COMPONENTS.version)}' #{COMPONENTS.root}/pkg/gems/"
      end
    end

    task :finalize_release_directory => 'all:stage_with_dependencies' do
      dirname = "#{COMPONENTS.root}/release/src/bosh/#{component}"

      rm_rf dirname
      mkdir_p dirname
      gemfile_lock_path = File.join(COMPONENTS.root, 'Gemfile.lock')
      lockfile = Bundler::LockfileParser.new(File.read(gemfile_lock_path))
      Dir.chdir dirname do
        Bundler::Resolver.resolve(
            Bundler.definition.send(:expand_dependencies, Bundler.definition.dependencies.select { |d| d.name == component }),
            Bundler.definition.index,
            {},
            lockfile.specs
        ).each do |spec|
          sh "cp /tmp/all_the_gems/#{Process.pid}/#{spec.name}-*.gem ."
          sh "cp /tmp/all_the_gems/#{Process.pid}/pg*.gem ." if COMPONENTS.has_db?(component)
          sh "cp /tmp/all_the_gems/#{Process.pid}/mysql*.gem ." if COMPONENTS.has_db?(component)
        end
      end
    end

    task :install => :pre_stage_latest do
      sh "gem install #{gem} --no-ri --no-rdoc"
    end

    task :prep_release => [:ensure_clean_state, :pre_stage_latest]

    task :push => :pre_stage_latest do
      sh "gem push #{gem}"
    end
  end
end

namespace :changelog do
  task :release_date do
    COMPONENTS.each do |fw|
      require 'date'
      replace = '\1(' + Date.today.strftime('%B %d, %Y') + ')'
      fname = File.join fw, 'CHANGELOG.md'

      contents = File.read(fname).sub(/^([^(]*)\(unreleased\)/, replace)
      File.open(fname, 'wb') { |f| f.write contents }
    end
  end

  task :release_summary do
    COMPONENTS.each do |fw|
      puts "## #{fw}"
      fname = File.join fw, 'CHANGELOG.md'
      contents = File.readlines fname
      contents.shift
      changes = []
      changes << contents.shift until contents.first =~ /^\*Bosh \d+\.\d+\.\d+/
      puts changes.reject { |change| change.strip.empty? }.join
      puts
    end
  end
end

namespace :all do
  desc "Prepare latest gem versions for staging"
  task :pre_stage_latest do
    rm_rf "pkg"
    mkdir_p "pkg/gems"
    COMPONENTS.map { |f| Rake::Task["#{f}:pre_stage_latest"].invoke  }
  end

  desc "Copy all staged gems into appropriate release subdirectories"
  task :finalize_release_directory => COMPONENTS.map { |f| "#{f}:finalize_release_directory" } do
    rm_rf "/tmp/all_the_gems/#{Process.pid}"
  end

  desc "Install all gems"
  task :install do
    mkdir_p "pkg/gems"
    COMPONENTS.map { |f| Rake::Task["#{f}:install"].invoke  }
  end

  desc "Push all gems to rubygems"
  task :push => COMPONENTS.map { |f| "#{f}:push" }

  task :stage_with_dependencies => :pre_stage_latest do
    mkdir_p "/tmp/all_the_gems/#{Process.pid}"
    sh "cp #{COMPONENTS.root}/pkg/gems/*.gem /tmp/all_the_gems/#{Process.pid}"
    sh "cp #{COMPONENTS.root}/vendor/cache/*.gem /tmp/all_the_gems/#{Process.pid}"
  end

  task :ensure_clean_state do
    unless `git status -s | grep -v BOSH_VERSION`.strip.empty?
      abort "[ABORTING] `git status` reports a dirty tree. Make sure all changes are committed"
    end

    unless ENV['SKIP_BRANCH'] || `git branch -ra | grep #{branch}`.strip.empty?
      abort "[ABORTING] `git branch` shows that #{branch} already exists. Has this version already\n"\
            "           been released? Git branching can be skipped by setting SKIP_BRANCH=1"
    end
  end

  task :commit do
    File.open('pkg/commit_message.txt', 'w') do |f|
      f.puts "# Preparing for #{COMPONENTS.version} release\n"
      f.puts
      f.puts "# UNCOMMENT THE LINE ABOVE TO APPROVE THIS COMMIT"
    end

    sh "git add . && git commit --verbose --template=pkg/commit_message.txt"
    rm_f "pkg/commit_message.txt"
  end

  task :branch do
    sh "git checkout -b #{branch}"
    sh "git push origin #{branch}"
  end

  desc "Meta task to build all gems, commit a release message, create a git branch and push the gems to rubygems"
  task :release => %w(ensure_clean_state pre_stage_latest commit branch push)
end
