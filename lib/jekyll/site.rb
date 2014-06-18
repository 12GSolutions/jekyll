module Jekyll
  class Site
    attr_accessor :config, :layouts, :posts, :pages, :static_files,
                  :exclude, :include, :source, :dest, :lsi, :highlighter,
                  :permalink_style, :time, :future, :unpublished, :safe, :plugins, :limit_posts,
                  :show_drafts, :keep_files, :baseurl, :data, :file_read_opts, :gems,
                  :plugin_manager, :jail

    attr_accessor :converters, :generators

    # Public: Initialize a new Site.
    #
    # config - A Hash containing site configuration details.
    def initialize(config)
      self.config = config.clone

      %w[safe lsi highlighter baseurl exclude include future unpublished
        show_drafts limit_posts keep_files gems].each do |opt|
        self.send("#{opt}=", config[opt])
      end

      self.source          = File.expand_path(config['source'])
      self.jail            = Jekyll::FileSystem::Jail.new(source, {
        :safe => self.safe,
        :site => self
      })
      self.dest            = File.expand_path(config['destination'])
      self.permalink_style = config['permalink'].to_sym

      self.plugin_manager = Jekyll::PluginManager.new(self)
      self.plugins        = plugin_manager.plugins_path

      self.file_read_opts = {}
      self.file_read_opts[:encoding] = config['encoding'] if config['encoding']

      reset
      setup
    end

    # Public: Read, process, and write this Site to output.
    #
    # Returns nothing.
    def process
      reset
      read
      generate
      render
      cleanup
      write
    end

    # Reset Site details.
    #
    # Returns nothing
    def reset
      self.time = (config['time'] ? Time.parse(config['time'].to_s) : Time.now)
      self.layouts = {}
      self.posts = []
      self.pages = []
      self.static_files = []
      self.data = {}
      @collections = nil

      if limit_posts < 0
        raise ArgumentError, "limit_posts must be a non-negative number"
      end
    end

    # Load necessary libraries, plugins, converters, and generators.
    #
    # Returns nothing.
    def setup
      ensure_not_in_dest

      plugin_manager.conscientious_require

      self.converters = instantiate_subclasses(Jekyll::Converter)
      self.generators = instantiate_subclasses(Jekyll::Generator)
    end

    # Check that the destination dir isn't the source dir or a directory
    # parent to the source dir.
    def ensure_not_in_dest
      dest_pathname = Pathname.new(dest)
      Pathname.new(source).ascend do |path|
        if path == dest_pathname
          raise FatalException.new "Destination directory cannot be or contain the Source directory."
        end
      end
    end

    # The list of collections and their corresponding Jekyll::Collection instances.
    # If config['collections'] is set, a new instance is created for each item in the collection.
    # If config['collections'] is not set, a new hash is returned.
    #
    # Returns a Hash containing collection name-to-instance pairs.
    def collections
      @collections ||= Hash[collection_names.map { |coll| [coll, Jekyll::Collection.new(self, coll)] } ]
    end

    # The list of collection names.
    #
    # Returns an array of collection names from the configuration,
    #   or an empty array if the `collections` key is not set.
    def collection_names
      case config['collections']
      when Hash
        config['collections'].keys
      when Array
        config['collections']
      when nil
        []
      else
        raise ArgumentError, "Your `collections` key must be a hash or an array."
      end
    end

    # Read Site data from disk and load it into internal data structures.
    #
    # Returns nothing.
    def read
      self.layouts = LayoutReader.new(self).read
      read_directories
      read_data(config['data_source'])
      read_collections
    end

    # Recursively traverse directories to find posts, pages and static files
    # that will become part of the site according to the rules in
    # filter_entries.
    #
    # dir - The String relative path of the directory to read. Default: ''.
    #
    # Returns nothing.
    def read_directories(dir = '')
      base    = File.join(source, dir)
      entries = jail.chdir(base) { filter_entries(jail.glob('*', File::FNM_DOTMATCH), base) }

      read_posts(dir)
      read_drafts(dir) if show_drafts
      posts.sort!
      limit_posts! if limit_posts > 0 # limit the posts if :limit_posts option is set

      entries.each do |f|
        f_abs = File.join(base, f)
        if jail.directory?(f_abs)
          f_rel = File.join(dir, f)
          read_directories(f_rel) unless dest.sub(/\/$/, '') == f_abs
        elsif has_yaml_header?(f_abs)
          page = Page.new(self, source, dir, f)
          pages << page if publisher.publish?(page)
        else
          static_files << StaticFile.new(self, source, dir, f)
        end
      end

      pages.sort_by!(&:name)
    end

    # Read all the files in <source>/<dir>/_posts and create a new Post
    # object with each one.
    #
    # dir - The String relative path of the directory to read.
    #
    # Returns nothing.
    def read_posts(dir)
      posts = read_content(dir, '_posts', Post)

      posts.each do |post|
        aggregate_post_info(post) if publisher.publish?(post)
      end
    end

    # Read all the files in <source>/<dir>/_drafts and create a new Post
    # object with each one.
    #
    # dir - The String relative path of the directory to read.
    #
    # Returns nothing.
    def read_drafts(dir)
      drafts = read_content(dir, '_drafts', Draft)

      drafts.each do |draft|
        if draft.published?
          aggregate_post_info(draft)
        end
      end
    end

    def read_content(dir, magic_dir, klass)
      get_entries(dir, magic_dir).map do |entry|
        klass.new(self, source, dir, entry) if klass.valid?(entry)
      end.reject do |entry|
        entry.nil?
      end
    end

    # Read and parse all yaml files under <source>/<dir>
    #
    # Returns nothing
    def read_data(dir)
      base = File.join(source, dir)
      read_data_to(base, self.data)
    end

    # Read and parse all yaml files under <dir> and add them to the
    # <data> variable.
    #
    # dir - The string absolute path of the directory to read.
    # data - The variable to which data will be added.
    #
    # Returns nothing
    def read_data_to(dir, data)
      return unless jail.directory?(dir) && jail.file_allowed?(dir)

      entries = jail.chdir(dir) do
        jail.glob('*').select do |file|
          jail.directory?(file) ||
            %w(.yaml .yml .json).include?(File.extname(file))
        end
      end

      entries.each do |entry|
        path = File.join(dir, entry)
        next unless jail.file_allowed?(path)

        key = sanitize_filename(File.basename(entry, '.*'))
        if jail.directory?(path)
          read_data_to(path, data[key] = {})
        else
          data[key] = SafeYAML.load(jail.read(path))
        end
      end
    end

    # Read in all collections specified in the configuration
    #
    # Returns nothing.
    def read_collections
      collections.each do |_, collection|
        collection.read unless collection.label.eql?("data")
      end
    end

    # Run each of the Generators.
    #
    # Returns nothing.
    def generate
      generators.each do |generator|
        generator.generate(self)
      end
    end

    # Render the site to the destination.
    #
    # Returns nothing.
    def render
      relative_permalinks_deprecation_method

      collections.each do |label, collection|
        collection.docs.each do |document|
          document.output = Jekyll::Renderer.new(self, document).run
        end
      end

      payload = site_payload
      [posts, pages].flatten.each do |page_or_post|
        page_or_post.render(layouts, payload)
      end
    rescue Errno::ENOENT => e
      # ignore missing layout dir
    end

    # Remove orphaned files and empty directories in destination.
    #
    # Returns nothing.
    def cleanup
      site_cleaner.cleanup!
    end

    # Write static files, pages, and posts.
    #
    # Returns nothing.
    def write
      each_site_file { |item| item.write(dest) }
    end

    # Construct a Hash of Posts indexed by the specified Post attribute.
    #
    # post_attr - The String name of the Post attribute.
    #
    # Examples
    #
    #   post_attr_hash('categories')
    #   # => { 'tech' => [<Post A>, <Post B>],
    #   #      'ruby' => [<Post B>] }
    #
    # Returns the Hash: { attr => posts } where
    #   attr  - One of the values for the requested attribute.
    #   posts - The Array of Posts with the given attr value.
    def post_attr_hash(post_attr)
      # Build a hash map based on the specified post attribute ( post attr =>
      # array of posts ) then sort each array in reverse order.
      hash = Hash.new { |h, key| h[key] = [] }
      posts.each { |p| p.send(post_attr.to_sym).each { |t| hash[t] << p } }
      hash.values.each { |posts| posts.sort!.reverse! }
      hash
    end

    def tags
      post_attr_hash('tags')
    end

    def categories
      post_attr_hash('categories')
    end

    # Prepare site data for site payload. The method maintains backward compatibility
    # if the key 'data' is already used in _config.yml.
    #
    # Returns the Hash to be hooked to site.data.
    def site_data
      config['data'] || data
    end

    # The Hash payload containing site-wide data.
    #
    # Returns the Hash: { "site" => data } where data is a Hash with keys:
    #   "time"       - The Time as specified in the configuration or the
    #                  current time if none was specified.
    #   "posts"      - The Array of Posts, sorted chronologically by post date
    #                  and then title.
    #   "pages"      - The Array of all Pages.
    #   "html_pages" - The Array of HTML Pages.
    #   "categories" - The Hash of category values and Posts.
    #                  See Site#post_attr_hash for type info.
    #   "tags"       - The Hash of tag values and Posts.
    #                  See Site#post_attr_hash for type info.
    def site_payload
      {
        "jekyll" => {
          "version" => Jekyll::VERSION,
          "environment" => Jekyll.env
        },
        "site"   => Utils.deep_merge_hashes(config,
          Utils.deep_merge_hashes(Hash[collections.map{|label, coll| [label, coll.docs]}], {
            "time"         => time,
            "posts"        => posts.sort { |a, b| b <=> a },
            "pages"        => pages,
            "static_files" => static_files.sort { |a, b| a.relative_path <=> b.relative_path },
            "html_pages"   => pages.reject { |page| !page.html? },
            "categories"   => post_attr_hash('categories'),
            "tags"         => post_attr_hash('tags'),
            "collections"  => collections,
            "documents"    => documents,
            "data"         => site_data
        }))
      }
    end

    # Filter out any files/directories that are hidden or backup files (start
    # with "." or "#" or end with "~"), or contain site content (start with "_"),
    # or are excluded in the site configuration, unless they are web server
    # files such as '.htaccess'.
    #
    # entries - The Array of String file/directory entries to filter.
    #
    # Returns the Array of filtered entries.
    def filter_entries(entries, base_directory = nil)
      EntryFilter.new(self, base_directory).filter(entries)
    end

    # Get the implementation class for the given Converter.
    #
    # klass - The Class of the Converter to fetch.
    #
    # Returns the Converter instance implementing the given Converter.
    def getConverterImpl(klass)
      matches = converters.select { |c| c.class == klass }
      if impl = matches.first
        impl
      else
        raise "Converter implementation not found for #{klass}"
      end
    end

    # Create array of instances of the subclasses of the class or module
    #   passed in as argument.
    #
    # klass - class or module containing the subclasses which should be
    #         instantiated
    #
    # Returns array of instances of subclasses of parameter
    def instantiate_subclasses(klass)
      klass.descendants.select do |c|
        !safe || c.safe
      end.sort.map do |c|
        c.new(config)
      end
    end

    # Read the entries from a particular directory for processing
    #
    # dir - The String relative path of the directory to read
    # subfolder - The String directory to read
    #
    # Returns the list of entries to process
    def get_entries(dir, subfolder)
      base = File.join(source, dir, subfolder)
      return [] unless jail.directory?(base)
      entries = jail.chdir(base) { filter_entries(jail.glob('**/*', File::FNM_DOTMATCH), base) }
      entries.delete_if { |e| jail.directory?(File.join(base, e)) }
    end

    # Aggregate post information
    #
    # post - The Post object to aggregate information for
    #
    # Returns nothing
    def aggregate_post_info(post)
      posts << post
    end

    def relative_permalinks_deprecation_method
      if config['relative_permalinks'] && has_relative_page?
        Jekyll.logger.warn "Deprecation:", "Starting in 2.0, permalinks for pages" +
                                            " in subfolders must be relative to the" +
                                            " site source directory, not the parent" +
                                            " directory. Check http://jekyllrb.com/docs/upgrading/"+
                                            " for more info."
      end
    end

    def docs_to_write
      documents.select(&:write?)
    end

    def documents
      collections.reduce(Set.new) do |docs, (_, collection)|
        docs.merge(collection.docs)
      end.to_a
    end

    def each_site_file
      %w(posts pages static_files docs_to_write).each do |type|
        send(type).each do |item|
          yield item
        end
      end
    end

    def frontmatter_defaults
      @frontmatter_defaults ||= Configuration::FrontmatterDefaults.new(self)
    end

    private

    def has_relative_page?
      pages.any? { |page| page.uses_relative_permalinks }
    end

    def has_yaml_header?(file)
      !!(jail.read(file, { :bytes => 5 }) =~ /\A---\r?\n/)
    end

    def limit_posts!
      limit = posts.length < limit_posts ? posts.length : limit_posts
      self.posts = posts[-limit, limit]
    end

    def site_cleaner
      @site_cleaner ||= Cleaner.new(self)
    end

    def sanitize_filename(name)
      name.gsub!(/[^\w\s_-]+/, '')
      name.gsub!(/(^|\b\s)\s+($|\s?\b)/, '\\1\\2')
      name.gsub(/\s+/, '_')
    end

    def publisher
      @publisher ||= Publisher.new(self)
    end
  end
end
