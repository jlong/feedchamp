require 'rubygems'
require 'camping'
require 'yaml'
require 'fileutils'
require 'simple-rss'
require 'net/http'
require 'time'

Camping.goes :FeedChamp

FeedChamp::Models::Base.logger = Logger.new('feedchamp.log')
FeedChamp::Models::Base.logger.level = Logger::WARN

class << FeedChamp
  def root
    File.dirname(__FILE__)
  end 
   
  def config
    @config ||= YAML.load(IO.read(File.join(root, 'config.yml'))).symbolize_keys
  end
  
  def feeds
    config[:feeds]
  end
  
  def title
    config[:title]
  end
  
  def feed
    config[:external_feed] || '/feed.xml'
  end
  
  def id
    config[:id]
  end
  
  def author
    config[:author] || title
  end
end

module FeedChamp::Models
  class Cache
    cattr_accessor :cache_directory
    self.cache_directory = File.join(FeedChamp.root, "cache")

    cattr_accessor :expire_time
    self.expire_time = 2.hours
    
    cattr_accessor :logger
    self.logger = FeedChamp::Models::Base.logger
    
    def self.rss_for(url)
      SimpleRSS.parse(File.read(filename_for(url)))
    end
    
    def self.filename_for(url)
      File.join(cache_directory, url.tr(':/', '_'))
    end

    def self.check_for_updates(url)
      filename = filename_for(url)
      FileUtils.mkpath(File.dirname(filename))
      last_modified = (File.exist?(filename) ? File.mtime(filename) : Time.at(0))
      if expire_time.ago > last_modified
        uri = URI::parse(url)
        http = Net::HTTP.start(uri.host, uri.port)
        response = http.get(uri.request_uri, "If-Modified-Since" => last_modified.httpdate)
        case response.code
        when '304'
          FileUtils.touch(filename)
          false
        when '200'
          open(filename, 'w') { |f| f.write(response.body) }
          true
        else
          logger.error("Invalid response code #{response.code} for feed <#{url}>")
          false
        end
      else
        false
      end
    end
  end

  class Entry < Base
    class << self
      def find_recent(limit = 50)
        find(:all, :limit => limit, :order => "updated DESC")
      end
      def process_feeds(feeds = FeedChamp.feeds)
        feeds.each do |feed|
          begin
            process_feed(Cache.rss_for(feed)) if Cache.check_for_updates(feed)
          rescue SimpleRSSError => e
            logger.error("#{e} <#{feed}>")
          end
        end
      end  
      def process_feed(rss)
        rss.items.each do |item|
          unless Entry.exists?(guid_for(item))
            Entry.create(
              :title => item.title,
              :content => fix_content(item.content || item.content_encoded || item.description || item.summary, rss.feed.link),
              :author => item.author || item.contributor || item.dc_creator,
              :link => item.link,
              :updated => item.updated || item.published || item.pubDate,
              :guid => guid_for(item),
              :site_link => rss.feed.link,
              :site_title => rss.feed.title
            )
          end
        end
      end
      def exists?(guid)
        !!find_by_guid(guid)
      end
      def guid_for(item)
        return item[:id] if item[:id]
        (%r{^(http|urn|tag):}i =~ item.guid ? item.guid : item.link)
      end
      def fix_content(content, site_link)
        content = CGI.unescapeHTML(content) unless /</ =~ content
        correct_urls(content, site_link)
      end
      def correct_urls(text, site_link)
        site_link += '/' unless site_link[-1..-1] == '/'
        text.gsub(%r{(src|href)=(['"])(?!http)([^'"]*?)}) do
          first_part = "#{$1}=#{$2}" 
          url = $3
          url = url[1..-1] if url[0..0] == '/'
          "#{first_part}#{site_link}#{url}"
        end
      end
    end
  end
  
  class CreateTheBasics < V 1.0
    def self.up
      create_table :feedchamp_entries, :force => true do |t|
        t.column :id,           :integer,  :null => false
        t.column :title,        :string
        t.column :description,  :text
        t.column :author,       :string
        t.column :link,         :string
        t.column :date,         :date
        t.column :guid,         :string
        t.column :site,         :string
      end
    end
    def self.down
      drop_table :feedchamp_entries
    end
  end

  class ImproveSiteHandling < V 1.1
    def self.up
      rename_column :feedchamp_entries, :site, :site_link
      add_column :feedchamp_entries, :site_title, :string
      Entry.delete_all
    end
    def self.down
      remove_column :feedchamp_entries, :site_title
      rename_column :feedchamp_entries, :site_link, :site
    end
  end
  
  class SwitchDateToUpdated < V 1.2
    def self.up
      remove_column :feedchamp_entries, :date
      add_column :feedchamp_entries, :updated, :datetime
      Entry.delete_all
    end
    def self.down
      remove_column :feedchamp_entries, :updated
      add_colun :feedchamp_entries, :date, :date
      Entry.delete_all
    end
  end
  
  class CleanUpNaming < V 1.3
    def self.up
      rename_column :feedchamp_entries, :description, :content
    end
    def self.down
      rename_column :feedchamp_entries, :content, :description
    end
  end
end

module FeedChamp::Controllers
  class Index < R '/'
    def get
      Entry.process_feeds
      @entries = Entry.find_recent
      render :index
    end
  end
  
  class Feed < R '/feed.xml'
    def get
      Entry.process_feeds
      @entries = Entry.find_recent(15)
      @headers["Content-Type"] = "application/atom+xml; charset=utf-8"
      render :feed
    end
  end
  
  class Style < R '/styles.css'
    def get
      @headers["Content-Type"] = "text/css; charset=utf-8"
      @body = %{
        body {
          font-family: "Lucidia Grande", Verdana, Arial, Helvetica, sans-serif;
          font-size: 80%;
          margin: 0;
          padding: 0;
        }
        #header {
          background: #69c;
          color: white;
          padding: 10px;
          position: fixed;
          top: 0;
          left: 0;
          width: 100%;
        }
        #header h1 {
          margin: 0;
        }
        #content {
          padding: 10px;
          padding-top: 20px;
          margin-top: 2em;
        }
        #content h3 {
          font-size: 150%;
        }
        #content .entry {
          border-bottom: 1px solid #ccc;
          padding-top: .5em;
          padding-bottom: 1.5em;
        }
        #content .entry .info {
          color: #999;
          font-size: 80%;
          margin-top: -1.5em;
        }
      }
    end
  end
end

module FeedChamp::Views
  def index
    html do
      head do
        title FeedChamp.title
        link :rel => 'stylesheet', :type => 'text/css', :href => '/styles.css', :media => 'screen'
        link :href => FeedChamp.feed, :rel => "alternate", :title => "Primary Feed", :type => "application/atom+xml"
      end
      body do
        div.header! do
          h1 FeedChamp.title
        end
        div.content! do
          @entries.each do |entry|
            div.entry do
              h3 { a(CGI.unescapeHTML(entry.title), :href => entry.link) }
              p.info do
                i = ["Posted to #{a(entry.site_title, :href => entry.site_link)}"]
                i << "by #{extract_author(entry.author)}" if entry.author
                i << "on #{entry.updated.strftime('%B %d, %Y')}"
                i.join(' ')
              end
              text entry.content.to_s
            end
          end
        end
      end
    end
  end
  
  def feed
    text %(<?xml version="1.0" encoding="utf-8"?>)
    text %(<feed xmlns="http://www.w3.org/2005/Atom">)
    text %(  <id>#{FeedChamp.id}</id>)
    text %(  <title>#{FeedChamp.title}</title>)
    text %(  <updated>#{@entries.first.updated.to_time.xmlschema}</updated>)
    text %(  <author><name>#{FeedChamp.author}</name></author>)
    text %(  <link href="http:#{URL().to_s}"/>)
    text %(  <link rel="self" href="http:#{URL('/feed.xml').to_s}"/>)
    text %(  <generator>FeedChamp</generator>)
    @entries.each do |entry|
      text %(  <entry>)
      text %(    <id>#{entry.guid.to_s}</id>)
      text %(    <title>#{entry.title.to_s}</title>)
      text %(    <updated>#{entry.updated.to_time.xmlschema}</updated>)
      text %(    <author><name>#{entry.author.to_s}</name></author>) if entry.author
      text %(    <content type="html">#{CGI.escapeHTML(entry.content.to_s)}</content>)
      text %(    <link rel="alternate" href="#{entry.link.to_s}"/>)
      text %(  </entry>)
    end
    text %(</feed>)
  end
  
  private
    def extract_author(author)
      if author =~ /\((.*?)\)/
        $1
      else
        author
      end
    end
    
    def text(t)
      super("#{t}\n")
    end
end

def FeedChamp.create
  FeedChamp::Models.create_schema :assume => (FeedChamp::Models::Entry.table_exists? ? 1.0 : 0.0)
end
