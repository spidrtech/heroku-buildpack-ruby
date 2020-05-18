# frozen_string_literal: true

require 'language_pack/fetcher'

# This class is responsible for installing and maintaining a
# reference to bundler. It contains access to bundler internals
# that are used to introspect a project such as detecting presence
# of gems and their versions.
#
# Example:
#
#   bundler = LanguagePack::Helpers::BundlerWrapper.new
#   bundler.install
#   bundler.version                 => "1.15.2"
#   bundler.dir_name                => "bundler-1.15.2"
#   bundler.has_gem?("railties")    => true
#   bundler.gem_version("railties") => "5.2.2"
#   bundler.clean
#
# Also used to determine the version of Ruby that a project is using
# based on `bundle platform --ruby`
#
#   bundler.ruby_version # => "ruby-2.5.1"
#   bundler.clean
#
# IMPORTANT: Calling `BundlerWrapper#install` on this class mutates the environment variable
# ENV['BUNDLE_GEMFILE']. If you're calling in a test context (or anything outside)
# of an isolated dyno, you must call `BundlerWrapper#clean`. To reset the environment
# variable:
#
#   bundler = LanguagePack::Helpers::BundlerWrapper.new
#   bundler.install
#   bundler.clean # <========== IMPORTANT =============
#
class LanguagePack::Helpers::BundlerWrapper
  include LanguagePack::ShellHelpers

  BLESSED_BUNDLER_VERSIONS = {}
  BLESSED_BUNDLER_VERSIONS["1"] = "1.17.3"
  BLESSED_BUNDLER_VERSIONS["2"] = "2.1.4"
  BUNDLED_WITH_REGEX = /^BUNDLED WITH$(\r?\n)   (?<version>(?<major>\d+)\.\d+\.\d+)/m

  class GemfileParseError < BuildpackError
    def initialize(error)
      msg = String.new("There was an error parsing your Gemfile, we cannot continue\n")
      msg << error
      super msg
    end
  end

  attr_reader :bundler_path

  def initialize(options = {})
    @bundler_tmp          = Pathname.new(Dir.mktmpdir)
    @fetcher              = options[:fetcher]      || LanguagePack::Fetcher.new("https://github.com/rubygems/") # coupling
    @gemfile_path         = options[:gemfile_path] || Pathname.new("./Gemfile")
    @gemfile_lock_path    = Pathname.new("#{@gemfile_path}.lock")
    @version              = @gemfile_lock_path.read(mode: "rt").match(BUNDLED_WITH_REGEX)[:version]

    @bundler_path         = options[:bundler_path] || @bundler_tmp.join(dir_name)
    @bundler_tar          = options[:bundler_tar]  || "bundler/archive/v#{version}.tar.gz"
    @orig_bundle_gemfile  = ENV['BUNDLE_GEMFILE']
    @path                 = Pathname.new("#{@bundler_path}/gems/#{dir_name}/lib")
  end

  def install
    ENV['BUNDLE_GEMFILE'] = @gemfile_path.to_s

    fetch_bundler
    $LOAD_PATH << @path
    require "bundler"
    self
  end

  def clean
    ENV['BUNDLE_GEMFILE'] = @orig_bundle_gemfile
    @bundler_tmp.rmtree if @bundler_tmp.directory?
  end

  def has_gem?(name)
    specs.key?(name)
  end

  def gem_version(name)
    instrument "ruby.gem_version" do
      if spec = specs[name]
        spec.version
      end
    end
  end

  # detects whether the Gemfile.lock contains the Windows platform
  # @return [Boolean] true if the Gemfile.lock was created on Windows
  def windows_gemfile_lock?
    platforms.detect do |platform|
      /mingw|mswin/.match(platform.os) if platform.is_a?(Gem::Platform)
    end
  end

  def specs
    @specs ||= lockfile_parser.specs.each_with_object({}) {|spec, hash| hash[spec.name] = spec }
  end

  def platforms
    @platforms ||= lockfile_parser.platforms
  end

  def version
    @version
  end

  def dir_name
    "bundler-#{version}"
  end

  def instrument(*args, &block)
    LanguagePack::Instrument.instrument(*args, &block)
  end

  def ruby_version
    instrument 'detect_ruby_version' do
      env = { "PATH"     => "#{bundler_path}/bin:#{ENV['PATH']}",
              "RUBYLIB"  => File.join(bundler_path, "gems", dir_name, "lib"),
              "GEM_PATH" => "#{bundler_path}:#{ENV["GEM_PATH"]}",
              "BUNDLE_DISABLE_VERSION_CHECK" => "true"
            }
      command = "bundle platform --ruby"

      # Silently check for ruby version
      output  = run_stdout(command, user_env: true, env: env).strip.lines.last

      # If there's a gem in the Gemfile (i.e. syntax error) emit error
      raise GemfileParseError.new(run("bundle check", user_env: true, env: env)) unless $?.success?
      if output.match(/No ruby version specified/)
        ""
      else
        output.chomp.sub('(', '').sub(')', '').sub(/(p-?\d+)/, ' \1').split.join('-')
      end
    end
  end

  def lockfile_parser
    @lockfile_parser ||= parse_gemfile_lock
  end

  private
  def fetch_bundler
    instrument 'fetch_bundler' do
      return true if Dir.exists?(bundler_path)

      topic("Installing bundler #{@version}")

      FileUtils.mkdir_p(bundler_path)
      Dir.chdir(bundler_path) do
        @fetcher.fetch_untar(@bundler_tar)
      end
      Dir["bin/*"].each {|path| `chmod 755 #{path}` }
    end
  end

  def parse_gemfile_lock
    instrument 'parse_bundle' do
      gemfile_contents = File.read(@gemfile_lock_path)
      Bundler::LockfileParser.new(gemfile_contents)
    end
  end

end
