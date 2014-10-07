require 'rubygems'
require 'net/https'
require 'fileutils'
require 'json'

module Gem
  class Src
    class Repository
      def self.tested_urls
        @tested_urls ||= []
      end

      def initialize(url)
        @url = url
      end

      def git_clone(clone_dir)
        return if @url.nil? || @url.empty?
        return if self.class.tested_urls.include?(@url)
        self.class.tested_urls << @url
        return if github? && !github_page_exists?

        if use_ghq?
          system 'ghq', 'get', @url
        else
          system 'git', 'clone', @url, clone_dir if git?
        end
      end

      private

      def github?
        URI.parse(@url).host == 'github.com'
      end

      def github_page_exists?
        Net::HTTP.new('github.com', 443).tap {|h| h.use_ssl = true }.request_head(@url).code != '404'
      end

      def git?
        !`git ls-remote #{@url} 2> /dev/null`.empty?
      end

      def use_ghq?
        ENV['GEMSRC_USE_GHQ'] || Gem.configuration[:gemsrc_use_ghq]
      end
    end
    
    attr_reader :installer

    def initialize(installer)
      @installer, @tested_repositories = installer, []
    end

    def clone_dir
      @clone_dir ||= if ENV['GEMSRC_CLONE_ROOT']
        File.expand_path installer.spec.name, ENV['GEMSRC_CLONE_ROOT']
      elsif Gem.configuration[:gemsrc_clone_root]
        File.expand_path installer.spec.name, Gem.configuration[:gemsrc_clone_root]
      else
        gem_dir = installer.respond_to?(:gem_dir) ? installer.gem_dir : File.expand_path(File.join(installer.gem_home, 'gems', installer.spec.full_name))
        File.join gem_dir, 'src'
      end
    end

    def github_url(url)
      if url =~ /\Ahttps?:\/\/([^.]+)\.github.com\/(.+)/
        if $1 == 'www'
          "https://github.com/#{$2}"
        elsif $1 == 'wiki'
          # https://wiki.github.com/foo/bar => https://github.com/foo/bar
          "https://github.com/#{$2}"
        else
          # https://foo.github.com/bar => https://github.com/foo/bar
          "https://github.com/#{$1}/#{$2}"
        end
      end
    end

    def api
      require 'open-uri'
      @api ||= open("http://rubygems.org/api/v1/gems/#{installer.spec.name}.yaml", &:read)
    rescue OpenURI::HTTPError
      ""
    end

    def source_code_uri
      api_uri_for('source_code')
    end

    def homepage_uri
      api_uri_for('homepage')
    end

    def github_organization_uri(name)
      "https://github.com/#{name}/#{name}"
    end

    def async_mode?
      ENV['GEMSRC_ASYNC'] || Gem.configuration[:gemsrc_async]
    end

    def git_clone_homepage_or_source_code_uri_or_homepage_uri_or_github_organization_uri
      return false if File.exist? clone_dir

      candidates = [
        installer.spec.homepage,
        github_url(installer.spec.homepage),
        source_code_uri,
        homepage_uri,
        github_url(homepage_uri),
        github_organization_uri(installer.spec.name),
      ]

      if async_mode?
        open(queue_file_path, 'w') do |f|
          f.write JSON.dump({
            'name' => installer.spec.name,
            'clone_dir' => clone_dir,
            'candidates' => candidates,
          })
        end
      else
        candidates.each do |candidate|
          break if Repository.new(candidate).git_clone(clone_dir)
        end
      end
    end

    def queue_file_path
      dir = File.expand_path('~/.gem-src-queue')
      FileUtils.mkdir_p(dir)
      File.join(dir, "#{Time.now.to_i}_#{installer.spec.name}.json")
    end

    def api_uri_for(key)
      uri = api[Regexp.new("^#{key}_uri: (.*)$"), 1]
      uri =~ /\Ahttps?:\/\// ? uri : nil
    end
  end
end


Gem.post_install do |installer|
  next true if installer.class.name == 'Bundler::Source::Path::Installer'
  Gem::Src.new(installer).git_clone_homepage_or_source_code_uri_or_homepage_uri_or_github_organization_uri
  true
end
