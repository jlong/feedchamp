require 'rubygems'
require 'rack'
require 'camping'
require 'feedchamp'

FeedChamp::Models::Base.establish_connection :adapter => 'sqlite3', :database => 'feedchamp.db'
FeedChamp.create

use Rack::CommonLogger
use Rack::ShowExceptions

app = Rack::Adapter::Camping.new(FeedChamp)
run app