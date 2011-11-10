require "thor"
require "thor/group"
require 'rack/test'
require 'find'
require 'hooks'

SHARED_SERVER = Middleman.server
SHARED_SERVER.set :environment, :build

module Middleman
  module ThorActions
    def tilt_template(source, *args, &block)
      config = args.last.is_a?(Hash) ? args.pop : {}
      destination = args.first || source
      
      request_path = destination.sub(/^#{SHARED_SERVER.build_dir}/, "")
      
      begin
        destination, request_path = SHARED_SERVER.reroute_builder(destination, request_path)
        
        request_path.gsub!(/\s/, "%20")
        response = Middleman::Builder.shared_rack.get(request_path)

        create_file destination, nil, config do
          response.body
        end if response.status == 200
      rescue
      end
    end
  end
  
  class Builder < Thor::Group
    include Thor::Actions
    include Middleman::ThorActions
    include ::Hooks
    
    define_hook :after_build
    
    def self.shared_rack
      @shared_rack ||= begin
        app = SHARED_SERVER.new!
        app_rack = SHARED_SERVER.build_new(app)
        mock = ::Rack::MockSession.new(app_rack)
        sess = ::Rack::Test::Session.new(mock)
        response = sess.get("__middleman__")
        sess
      end
    end
    
    class_option :relative, :type => :boolean, :aliases => "-r", :default => false, :desc => 'Override the config.rb file and force relative urls'
    class_option :glob, :type => :string, :aliases => "-g", :default => nil, :desc => 'Build a subset of the project'
    
    def initialize(*args)
      super
      
      if options.has_key?("relative") && options["relative"]
        SHARED_SERVER.activate :relative_assets
      end
    end
    
    def source_paths
      @source_paths ||= [
        SHARED_SERVER.root
      ]
    end
    
    def build_all_files
      self.class.shared_rack
      
      opts = { }
      opts[:glob]  = options["glob"]  if options.has_key?("glob")
      opts[:clean] = options["clean"] if options.has_key?("clean")
      
      action GlobAction.new(self, SHARED_SERVER, opts)
      
      run_hook :after_build
    end
    
    # Old API
    def self.after_run(name, &block)
      after_build(&block)
    end
  end
  
  class GlobAction < ::Thor::Actions::EmptyDirectory
    attr_reader :source

    def initialize(base, app, config={}, &block)
      @app         = app
      source       = @app.views
      @destination = @app.build_dir
      
      @source = File.expand_path(base.find_in_source_paths(source.to_s))
      
      super(base, destination, config)
    end

    def invoke!
      queue_current_paths if cleaning?
      execute!
      clean! if cleaning?
    end

    def revoke!
      execute!
    end

  protected
  
    def clean!
      files       = @cleaning_queue.select { |q| File.file? q }
      directories = @cleaning_queue.select { |q| File.directory? q }

      files.each do |f| 
        base.remove_file f, :force => true
      end

      directories = directories.sort_by {|d| d.length }.reverse!

      directories.each do |d|
        base.remove_file d, :force => true if directory_empty? d 
      end
    end
  
    def cleaning?
      @config.has_key?(:clean) && @config[:clean]
    end

    def directory_empty?(directory)
      Dir["#{directory}/*"].empty?
    end

    def queue_current_paths
      @cleaning_queue = []
      Find.find(@destination) do |path|
        next if path.match(/\/\./)
        unless path == destination
          @cleaning_queue << path.sub(@destination, destination[/([^\/]+?)$/])
        end
      end
    end
    
    def execute!
      paths = @app.sitemap.all_paths.sort do |a, b|
        a_dir = a.split("/").first
        b_dir = b.split("/").first
      
        if a_dir == @app.images_dir
          -1
        elsif b_dir == @app.images_dir
          1
        else
          0
        end
      end
      
      paths.each do |path|
        file_source = path
        file_destination = File.join(given_destination, file_source.gsub(source, '.'))
        file_destination.gsub!('/./', '/')
        
        if @app.sitemap.generic_path?(file_source)
          # no-op
        elsif @app.sitemap.proxied_path?(file_source)
          file_source = @app.sitemap.path_target(file_source)
        elsif @app.sitemap.ignored_path?(file_source)
          next
        end
        
        @cleaning_queue.delete(file_destination) if cleaning?
        
        if @config[:glob]
          next unless File.fnmatch(@config[:glob], file_source)
        end
        
        base.tilt_template(file_source, file_destination, { :force => true })
      end
    end
  end
end