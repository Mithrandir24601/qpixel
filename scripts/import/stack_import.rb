require 'ostruct'
require 'optparse'
require 'open-uri'
require 'csv'

require_relative 'api_import'
require_relative 'dump_import'
require_relative 'database_import'

$logger = ::Logger.new(STDOUT)
$logger.level = :info

def msg2str(msg)
  case msg
  when ::String
    msg
  when ::Exception
    "#{msg.message} (#{msg.class})\n" <<
      (msg.backtrace || []).join("\n")
  else
    msg.inspect
  end
end

$logger.formatter = proc do |severity, time, progname, msg|
  colors = { 'DEBUG' => "\033[0;37m", 'INFO' => "\033[1;36m", 'WARN' => "\033[1;33m", 'ERROR' => "\033[1;31m",
             'FATAL' => "\033[0;31m" }
  "%s, [%s #%d] %s%5s%s -- %s: %s\n" % [severity[0..0], time.strftime('%Y-%m-%d %H:%M:%S'), $$, colors[severity],
                                        severity, "\033[0m", progname, msg2str(msg)]
end

def domain_from_api_param(api_param)
  nonstandard = {
    stackoverflow: '.com',
    superuser: '.com',
    serverfault: '.net',
    askubuntu: '.com',
    mathoverflow: '.net'
  }
  if nonstandard.keys.include? api_param.to_sym
    "#{api_param}#{nonstandard[api_param.to_sym]}"
  else
    "#{api_param}.stackexchange.com"
  end
end

@options = OpenStruct.new
opt_parser = OptionParser.new do |opts|
  opts.banner = "Usage: rails r stack_import.rb [options]"

  opts.on('-s', '--site=SITE', "Stack Exchange site API parameter to operate on") do |site|
    @options.site = site
  end

  opts.on('-k', '--key=KEY', 'Stack Exchange API key') do |key|
    @options.key = key
  end

  opts.on('-q', '--query=REVISION_ID', 'Import posts whose IDs are returned by the SEDE query provided') do |query|
    @options.query = query
  end

  opts.on('-d', '--dump=FILE', 'Specify the path to the decompressed data dump directory') do |path|
    @options.path = path
  end

  opts.on('-i', '--quiet', 'Produce less output') do
    $logger.level = :warn
  end

  opts.on('-v', '--verbose', 'Produce more output') do
    $logger.level = :debug
  end

  opts.on('-c', '--community=ID', Integer, 'Specify the community ID to add imported content to') do |community|
    @options.community = community
  end

  opts.on('-t', '--category=ID', Integer, 'Specify the category ID which imported posts should be added') do |category|
    @options.category = category
  end

  opts.on('-m', '--mode=MODE', 'Specify the mode to work in (full, process, or import)') do |mode|
    @options.mode = mode || 'full'
  end

  opts.on('-a', '--tag-set=ID', 'Specify the tag set into which to add new tags') do |tag_set|
    @options.tag_set = tag_set
  end

  opts.on('--skip-tags', 'Skip updating tag associations if you don\'t care about them for some reason.') do
    @options.skip_tags = true
  end

  opts.on_tail('-h', '--help', 'Show this message') do
    puts opts
    exit
  end
end
opt_parser.parse!

require = [:query, :path, :community, :category, :mode, :tag_set]

require.each do |r|
  unless @options[r].present?
    $logger.fatal "#{r.to_s} must be provided. Use --help for a list of parameters."
    exit 1
  end
end

unless @options.key.present?
  $logger.warn 'No key supplied. Can run without for a limited import, but larger datasets will need a key.'
end

RequestContext.community = Community.find(@options.community)

# ==================================================================================================================== #

if @options.mode == 'full' || @options.mode == 'process'
  Dir.chdir Rails.root
  unless Dir.exist?(Rails.root.join('import-data'))
    Dir.mkdir(Rails.root.join('import-data'))
  end

  domain = domain_from_api_param(@options.site)

  query_response = Net::HTTP.get_response(URI("https://data.stackexchange.com/#{@options.site}/csv/#{@options.query}"))
  query_results = CSV.parse(query_response.body)
  required_ids = query_results.map { |r| r[0].to_s }.drop(1)

  api_importer = APIImport.new @options

  posts, posts_file = DumpImport.do_xml_transform(domain, 'Posts', @options) do |rows|
    ids = rows.map { |r| r['id'].to_s }
    missing = required_ids.select { |e| !ids.include? e }
    excess = ids.select { |e| !required_ids.include? e }
    $logger.info "#{ids.size} post rows in dump, #{missing.size} to get from API, #{excess.size} excess"

    rows = rows.select { |r| !excess.include? r['id'].to_s }
    rows = rows.concat(api_importer.posts(missing) || [])

    rows
  end

  required_user_ids = posts.map { |p| p['owner_user_id'] }.uniq
  users, users_file = DumpImport.do_xml_transform(domain, 'Users', @options) do |rows|
    ids = rows.map { |r| r['id'].to_s }
    missing = required_user_ids.select { |e| !ids.include? e }
    excess = ids.select { |e| !required_user_ids.include? e }
    $logger.info "#{ids.size} user rows in dump, #{missing.size} to get from API, #{excess.size} excess"

    rows = rows.select { |r| !excess.include? r['id'].to_s }
    rows = rows.concat(api_importer.users(missing) || [])

    rows
  end

  tags_file = DumpImport.generate_tags(posts, @options)

  if @options.mode == 'process'
    files = [users_file, posts_file, tags_file].map { |s| s.to_s.gsub("#{Rails.root.to_s}/", '') }
    `tar -cvzf qpixel-import.tar.gz #{files.join(' ')}`
    $logger.info 'Written qpixel-import.tar.gz.'
    exit 0
  end
end

if @options.mode == 'import'
  Dir.chdir Rails.root
  `tar -xvzf qpixel-import.tar.gz`
  $logger.info 'Decompressed & unarchived qpixel-import.tar.gz.'
  # Now we have all the files in import-data/ and can continue with the same process for either
  # full or import-only modes
end

if @options.mode == 'import' || @options.mode == 'full'
  @importer = DatabaseImport.new @options, domain_from_api_param(@options.site)
  @importer.load_data('import-data/Users_Formatted.xml', 'users',
                      ['id', 'created_at', 'username', 'website', 'profile', 'profile_markdown', 'se_acct_id'])
  @importer.load_data('import-data/Posts_Formatted.xml', 'posts',
                      ['id', 'post_type_id', 'created_at', 'score', 'body', 'body_markdown', 'user_id', 'last_activity',
                       'title', 'tags_cache', 'answer_count', 'parent_id', 'att_source', 'att_license_name',
                       'att_license_link', 'category_id', 'community_id'])
  @importer.load_data('import-data/Tags_Formatted.xml', 'tags',
                      ['community_id', 'tag_set_id', 'name', 'created_at', 'updated_at'])

  @importer.run
end
