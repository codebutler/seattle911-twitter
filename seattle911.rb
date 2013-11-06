#!/usr/bin/ruby

# @seattle911 twitter bot
# Eric Butler <eric@codebutler.com>

require 'rubygems'
require 'bundler/setup'

require 'time'
require 'tzinfo'
require 'active_support/all'
require 'hpricot'
require 'open-uri'
require 'timeout'
require 'twitter'
require 'bitly'
require 'lockfile'
require 'logger'
require 'google/geo'

Bitly.use_api_version_3

URL = 'http://www2.seattle.gov/fire/realtime911/getRecsForDatePub.asp?action=Today&incDate=&rad1=des'

class Seattle911Tweeter
  def initialize(dir)
    @config_file = File.join(dir, 'config.yml')
    @state_file  = File.join(dir, 'seattle911.state')
    @log_file    = File.join(dir, 'seattle911.log')
    @lock_file   = File.join(dir, 'seattle911.lock')

    # Initialize logger
    @logger = Logger.new(@log_file)
    @logger.level = Logger::DEBUG
    
    # Load config file
    raise "Config file '#{@config_file}' not found." if !File.exists?(@config_file)
    yml = File.open(@config_file) {|f| f.read }
    @config = YAML::load(yml)
    
    # Load state
    if File.exists?(@state_file)
      @last_num = File.open(@state_file) {|f| f.read.to_i }
    end
    
    # Configure bit.ly client
    @bitly = Bitly.new(@config[:bitly][:username], @config[:bitly][:key])
    
    # Load twitter OAuth config
    twitter_conf    = @config[:twitter]    
    consumer_key    = twitter_conf[:consumer_key]
    consumer_secret = twitter_conf[:consumer_secret]
    
    # Get Twitter OAuth access token if needed
    if !twitter_conf[:access_token]
      username = twitter_conf[:username]
      password = twitter_conf[:password]
      
      consumer = OAuth::Consumer.new(consumer_key, consumer_secret, {
        :site=> "https://api.twitter.com"
      })

      request_token = consumer.get_request_token
      
      puts "Visit the following URL to obtain the authentication PIN:"
      puts request_token.authorize_url
      
      print 'PIN: '
      pin = gets.chomp
      
      access_token = request_token.get_access_token(:oauth_verifier => pin)
      
      # Cache the access token.
      # FIXME: Store this in the state file instead.
      twitter_conf[:access_token] = {
        :token  => access_token.token,
        :secret => access_token.secret
      }
      File.open(@config_file, 'w') {|f| f.write(YAML::dump(@config)) }
    end
    
    access_token = twitter_conf[:access_token]
    
    # Configure twitter client
    Twitter.configure do |config|
      config.consumer_key       = consumer_key
      config.consumer_secret    = consumer_secret
      config.oauth_token        = access_token[:token]
      config.oauth_token_secret = access_token[:secret]
    end
  end
  
  def tweet_incidents
    begin
      Lockfile.new(@lock_file, :retries => 0) do
        # Scrape incidents
        incidents = self.scrape_incidents
        
        # Process each incident
        if incidents
          incidents.each do |incident|
            # For now we only list incidents as they become active.
            if incident[:status] == 'active' && incident[:num].to_i > self.last_num
              date = Time.strptime("#{incident[:date]}", '%m/%d/%Y %I:%M:%S %p')
              date = TZInfo::Timezone.get('America/Los_Angeles').local_to_utc(date)
              # Skip anything more than 10 minutes old.
              if date >= 10.minutes.ago.utc
    	          cleaned_location = incident[:location].gsub(/\//, ' and ') + ', Seattle WA'

          	    options = {}
          	    #geo = Google::Geo.new(@config[:gmaps][:key])
          	    #results = geo.locate(cleaned_location)
          	    #if results.length > 0
          	    #  options[:lat] = results.first.lat
          	    #  options[:long] = results.first.lng
          	    #end

                msg = "#{incident[:type]} @ #{incident[:location]} (#{incident[:units]})"
                q = "#{cleaned_location} (#{incident[:date]} - #{incident[:type]} - Units: #{incident[:units]} - Incident: ##{incident[:num]})"
                long_url = "http://maps.google.com/maps?q=#{CGI::escape(q)}"
                begin
                  timeout(60) do
                    bitly_url = @bitly.shorten(long_url)
                    msg += " #{bitly_url.short_url}"
                  end
                rescue TimeoutError
                  # Well, I guess we won't add a link to this one.
                  @logger.warn "bitly timeout!"
                rescue Exception => ex
                  # ...or here either!
                  @logger.warn "bitly failure! #{ex}"
                end
                @logger.debug msg
                self.last_num = incident[:num]
                begin
                  timeout(60) do
                    Twitter.update(msg, options)
                  end
                rescue Exception => ex
                  # Twitter goes down and randomly screws up all day long...
                  @logger.warn "Ignoring twitter failure: #{ex}"
                end
              end
            end
          end
        else  
          raise 'Got nothing!'
        end
      end
    rescue Exception => ex
      ignored_exceptions = [OpenURI::HTTPError, SocketError, Errno::EHOSTUNREACH, TimeoutError]
      if ignored_exceptions.include?(ex.class)
        @logger.debug "Ignoring exception: #{ex}"
      elsif ex.is_a?(Lockfile::MaxTriesLockError)
        @logger.debug 'Another instance of this script is already running. Existing'
      else
        @logger.error "#{ex.message} #{ex.backtrace.join("\n")}"
        raise ex
      end
    end
  end

  protected
  
  def last_num
    @last_num || 0
  end
  
  def last_num=(num)
    num = num.to_i
    File.open(@state_file, 'w') do |f|
      f.write(num)
    end
    @last_num = num
  end
  
  def scrape_incidents
    incidents = []
    timeout(60) do
      doc = Hpricot(open(URL))
      (doc/"table[@cellpadding='2'] tr").each do |e|
        cells = (e/'td')
        incidents << {
          :status   => cells[0]['class'],
          :date     => cells[0].inner_html,
          :num      => cells[1].inner_html[1..-1],
          :level    => cells[2].inner_html,
          :units    => cells[3].inner_html,
          :location => cells[4].inner_html,
          :type     => cells[5].inner_html,
        }
      end
    end
    incidents
  end
end


if $0 == __FILE__
  begin
    dir = File.dirname(__FILE__)
    tweeter = Seattle911Tweeter.new(dir)
    tweeter.tweet_incidents
  rescue Exception => ex
    $stderr.puts "#{ex.message} #{ex.backtrace.join("\n")}"
    exit 1
  end
end
