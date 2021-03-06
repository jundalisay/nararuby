require 'rubygems'
require 'neography'
require './environments'
require 'uri'
require 'json'
require 'sinatra/base'
require 'sinatra/activerecord'
# require 'paypal-sdk-rest' check other nara project controllers if you want to implement paypal

class Nara < Sinatra::Base
  set :erb, :format => :html5 
  set :app_file, __FILE__

  configure :test do
    require 'net-http-spy'
    Net::HTTP.http_logger_options = {:verbose => true} 
  end

  configure do #app-wide settings
    enable :sessions
    set :session_secret, ENV['SESSION_SECRET'] || 'this is a secret!'
  end

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  end

  helpers do
    def link_to(url, text=url, opts={})
      attributes = ""
      opts.each { |key,value| attributes << key.to_s << "=\"" << value << "\" "}
      "<a href=\"#{url}\" #{attributes}>#{text}</a>"
    end
  end
  
  # STARTS THE 'REST INSTANCE'
  def neo
      @neo = Neography::Rest.new(ENV["GRAPHENEDB_URL"] || "http://localhost:7474")
  end
  
  #TURN RUBY STUFF TO {JSON-KIND STUFF}
   def hashify(results)
    results["data"].map {|row| Hash[*results["columns"].zip(row).flatten] }
  end

  def create_graph
    return if neo.execute_query("MATCH (n:Organization) RETURN COUNT(n)")["data"].first.first > 1

    organizations = %w[Farm KFC Pepsi]
    products = %w[chicken_raw chicken_fried softdrinks]
    locations = %w[New\ York\ City Iowa]
      
    cypher = "CREATE (n:Organization {nodes}) RETURN  ID(n) AS id, n.name AS name"
    nodes = []
    organizations.each { |n| nodes <<  {"name" => n} }
    organizations = hashify(neo.execute_query(cypher, {:nodes => nodes}))

    cypher = "CREATE (n:Location {nodes}) RETURN  ID(n) AS id, n.name AS name"
    nodes = []
    locations.each { |n| nodes << {"name" => n} }
    locations = hashify(neo.execute_query(cypher, {:nodes => nodes}))
  
    cypher = "CREATE (n:Product {nodes}) RETURN  ID(n) AS id, n.name AS name"
    nodes = []  
    products.each { |n| nodes << {"name" => n} }
    products = hashify(neo.execute_query(cypher, {:nodes => nodes}))
    
    neo.execute_query("CREATE INDEX ON :Organization(name)")
    neo.execute_query("CREATE INDEX ON :Location(name)")
    neo.execute_query("CREATE INDEX ON :Product(name)")
  
    # Creating relationships manually:
    commands = []
    farm = organizations[0]
    kfc = organizations[1]
    pepsi = organizations[2]
    nyc = locations[0]
    iowa = locations[1]
    chicken_raw = products[0]
    chicken_fried = products[1]
    softdrinks = products[2]
    
    commands << [:create_relationship, "located_in", pepsi["id"], nyc["id"], nil]    
    commands << [:create_relationship, "located_in", kfc["id"], nyc["id"], nil]    
    commands << [:create_relationship, "located_in", farm["id"], iowa["id"], nil]    
    
    commands << [:create_relationship, "makes", farm["id"], chicken_raw["id"], nil]    
    commands << [:create_relationship, "makes", kfc["id"], chicken_fried["id"], nil]    
    commands << [:create_relationship, "makes", pepsi["id"], softdrinks["id"], nil] 
    
    commands << [:create_relationship, "buys", kfc["id"], chicken_raw["id"], nil]        
    commands << [:create_relationship, "buys", pepsi["id"], chicken_fried["id"], nil]        
    commands << [:create_relationship, "buys", kfc["id"], softdrinks["id"], nil]                
    commands << [:create_relationship, "buys", farm["id"], chicken_fried["id"], nil]  

    neo.batch *commands
  end

  def node_id(node)
    case node
      when Hash
        node["self"].split('/').last
      when String
        node.split('/').last
      else
        node
    end
  end

  def get_properties(node)
    properties = ""
#    node.each_pair do |key, value|
#      if key == "avatar_url"
#        properties << "<img src='#{value}'>"
#      else
#        properties << "<b>#{key}:</b> #{value}"
#      end
#    end
#    properties + ""
  end

  get '/resources/show' do
    content_type :json

    cypher = "START me=node(#{params[:id]}) 
              OPTIONAL MATCH me -[r]- related
              RETURN me, r, related"

    connections = neo.execute_query(cypher)["data"]   
 
    me = connections[0][0]["data"]
    
    relationships = []
    if connections[0][1]
      connections.group_by{|group| group[1]["type"]}.each do |key,values| 
        relationships <<  {:id => key, 
                     :name => key,
                     :values => values.collect{|n| n[2]["data"].merge({:id => node_id(n[2]) }) } }
      end
    end

    relationships = [{"name" => "No Relationships","values" => [{"id" => "#{params[:id]}","name" => "No Relationships "}]}] if relationships.empty?

    @node = {:details_html => "<h1>#{me["name"]}</h1>\n
    <p class='summary'>\n
    #{get_properties(me)}</p>\n
    <form action='/skus'> <button>View This</button></form>\n
    ",

                :data => {:attributes => relationships, 
                          :name => me["name"],
                          :id => params[:id]}
              }
    @node.to_json
  end

######### START / SEARCH ##############################################

# orig
#   get '/' do
#     create_graph
#     @neoid = params["neoid"] || 1

  get '/' do
    if current_user
      create_graph
      @neoid = params["neoid"] || 1
      erb :'index'
    else
      redirect("/splash")
    end
  end

get '/search' do
  @skus = Sku.all
    if params[:search]
      @skus = Sku.search(params[:search]).order("created_at DESC")
    else
      @skus = Sku.all.order("created_at DESC")
  end
  erb :'search'
end

###### AUTH CONTROLLERS #################################################

  get '/splash' do
    erb :'auth/splash'
  end

  get '/login' do
    erb :'auth/login'
  end

  post '/login' do
    user = User.find_by(name: params[:user][:name]).try(:authenticate, params[:user][:password])
    if user
      session[:user_id] = user.id
      redirect("/")
    else
      set_error("Username not found or password incorrect.")
      redirect("/login")
    end
  end

  get '/signup' do
    user = User.new
    erb :'auth/signup'
  end

  post '/signup' do
    user = User.new(params[:user])
    if user.save
      session[:user_id] = user.id  #session is a hash in a cookie
      redirect("/skus/needs")
    else
      session[:error] = user.errors.messages
      redirect("/signup")
    end
  end

get '/logout' do
  session[:user_id] = nil
  redirect("/")
end

###### USER COMPANY CONTROLLERS #################################################

get '/users' do
  @users = User.order("created_at DESC")  
    erb :"users/index"
end

  get "/users/:id" do
    @user = User.find(params[:id])
    @name = @user.name
    erb :"users/view"
  end

################ AUTH AND ERROR HELPERS #################################

def current_user
  if session[:user_id]  # checks if there is session called user_id
    return User.find(session[:user_id]) # if there's a session 'user_id', find that user 
  else
    return nil # if there is no session called user_id, then current_user is nil
  end
end

def display_error
  error = session[:error]
  session[:error] = nil

  if error
    return erb :'errors/error_display', layout: false, locals: {errors: error}
  else
    return ""
  end
end

def set_error(msg)
  session[:error] = {"Error" => [msg]}
end

# TRY THIS
# def set_notif(msg)
#   session[:notif] = {"Notif" => [msg]}
# end

# def display_notif
#   notif = session[:notif]
#   session[:notif] = nil

#   if notif
#     return erb :'errors/notif_display', layout: false, locals: {notif: notif}
#   else
#     return ""
#   end
# end

####### SKU CONTROLLERS ################################################

  get '/skus' do
  @skus = Sku.where(need: 'supplier').order("created_at DESC")
    if current_user
      @myskus = Sku.where("user_id = ?", current_user.id).order("created_at DESC")
    else
      @myskus = Sku.where("user_id = ?", nil).order("created_at DESC")
    end
    erb :"skus/index"
  end

  get "/skus/needs" do  
    @sku = Sku.new
    erb :"/skus/needs"
  end

  post "/skus/needs" do
    @sku = Sku.new(params[:sku].merge(user_id: current_user.id))
    @sku.save
    session[:user_id] = current_user.id    
    redirect "/skus/supplies"
  end

  get "/skus/supplies" do  
    @sku = Sku.new
    erb :"/skus/supplies"
  end

  post "/skus/supplies" do
    @sku = Sku.new(params[:sku].merge(user_id: current_user.id))
    @sku.save
    session[:user_id] = current_user.id    
    redirect "/"
  end

  get "/skus/create" do
    if current_user
      @name = "New sku"
      @sku = Sku.new
        erb :"skus/create"
    else
      redirect("/login")
    end
  end

    post "/skus" do
    user_id = current_user.id # i did thos so maybe deletable?
    @sku = Sku.new(params[:sku].merge(user_id: current_user.id))
      if @sku.save
        redirect "skus/#{@sku.id}"
        session[:sku_id] = @sku.id  #session is a hash in a cookie
      else
        session[:error] = @sku.errors.messages
        # set_error("SKU name cannot be blank or duplicate. Ensure that Make or Need is specified")
        redirect "skus/create"
      end
    end

  get "/skus/:id" do
    if current_user
    @sku = Sku.find(params[:id])
    erb :"skus/view"
    else
      redirect("/login")
    end
  end

    get "/skus/:id/edit" do
   if current_user 
      @sku = Sku.find(params[:id])
      @name = "Edit Sku"
#    if current_user = Sku.find(params[:id]).user
      erb :"skus/edit"
    else
      redirect("/login")
    end
    end

      post "/skus/:id" do
        @sku = Sku.find(params[:id])
        @sku.update(params[:sku])
        redirect "/skus/#{@sku.id}"
      end

    get '/skus/:id/del' do
    if current_user
      @sku = Sku.find(params[:id])
      @sku.destroy
      redirect ("/skus")
    else
      redirect("/login")
    end
    end

################ SERVICES CONTROLLERS #############################################################

get '/services' do
  @services = Service.order("created_at DESC")  
    erb :"services/index"
  end

  get "/services/create" do
    if current_user
      @name = "New Service"
      @service = Service.new
        erb :"services/create"
    else
      redirect("/login")
    end
  end

    post "/services" do
    @service = Service.new(params[:service].merge(user_id: current_user.id))
      if @service.save
        redirect "services/#{@service.id}"
#        session[:service_id] = @service.id  #session is a hash in a cookie
      else
        set_error("Service name cannot be blank or duplicate")
        redirect "services/create"
      end
    end

  get "/services/:id" do
    if current_user
   @service = Service.find(params[:id])
    erb :"services/view"
    else
      redirect("/login")
    end
  end


    get "/services/:id/edit" do
      @service = Service.find(params[:id])
      @name = "Edit Service"
      erb :"services/edit"
    end

      post "/services/:id" do
        @service = Service.find(params[:id])
        @service.update(params[:service])
        redirect "/services/#{@service.id}"
      end

    get '/services/:id/del' do
      @service = Service.find(params[:id])
      @service.destroy
      redirect ("/services")
    end

######### TRADES CONTROLLERS ##############################################

  get '/trades' do
#    @trades = Trade.where(recipient_name: "Productos").first
#    @trades = Trade.where(recipient: current_user.name).order("created_at DESC")
    @trades = Trade.where("recipient2 = ? OR user_id = ?", current_user.name, current_user.id).order("created_at DESC")
#    @trades = Trade.order("created_at DESC")  
    erb :"trades/index"
  end

  get '/trades/create' do
    @theirskus = Sku.where("user_id <> ? AND need = ?", current_user.id, "supplier").order("created_at DESC")  #for the select populate
    @ourskus = Sku.where("user_id = ? AND need = ?", current_user.id, "supplier").order("created_at DESC")
    @suppliers = User.where("id <> ?", current_user.id).order("created_at DESC")
#    @users = User.all  #for the select populate
#    { :users => @users }.to_json #to turn it to JSON-KINDn
#    user = User.joins(:skus).where("user.id" = user_id)
    @trade = Trade.new
    erb :"trades/create"
  end

get '/trades/sug' do
    erb :"trades/sug"
  end


    post '/trades' do
    @trade = Trade.new(params[:trade].merge(user_id: current_user.id))
      if @trade.save
         redirect 'trades/ok'
#        redirect "trades/#{@trade.id}"
#        session[:trade_id] = @trade.id  #session is a hash in a cookie
      else
        session[:error] = @trade.errors.messages
        # set_error("SKU name cannot be blank or duplicate. Ensure that Make or Need is specified")
        redirect 'trades/create'
      end
    end

  get '/trades/ok' do
    erb :"trades/ok"  
  end
  
  get "/trades/:id" do
    @trade = Trade.find(params[:id])
    erb :"trades/view"
  end

   post '/trades/:id' do
     @trade = Trade.find(params[:id])
     @trade.update(params[:trade])
#     @title = 'updated!' #not working
#     @notif = 'Username not found or password incorrect'
#    @trade = Trade.new(params[:trade].merge(user_id: current_user.id))
     redirect '/trades'
#      erb :'trades/updated'
#     redirect 'trades/ok'
#        redirect "trades/#{@trade.id}"
#        session[:trade_id] = @trade.id  #session is a hash in a cookie
    end
 
    get '/trades/:id/del' do
    if current_user
      trade = Trade.find(params[:id])
      trade.destroy
      redirect ("/trades")
    else
      redirect("/login")
    end
    end

######### MAP CONTROLLERS ##############################################

  get '/mapbiz' do
    erb :mapbiz
  end

  get '/mapdisaster' do
    erb :"map/mapdis"
  end

  get '/mapdisleyte' do
    erb :mapdisleyte
  end

  get '/mapdismamasapano' do
    erb :mapdismamasapano
  end

  get '/mapdisnepal' do
    erb :"map/mapdisnepal"
  end

  get '/mapdisbesi' do
    erb :"map/mapdisbesi"
  end

  

######### DONATIONS CONTROLLERS ##############################################

  get '/donations' do
    if current_user
      @donations = Donation.where("deliverer2 = ? OR deliverer3 = ? OR deliverer4 = ? OR deliverer5 = ? OR user_id = ?", current_user.name, current_user.name, current_user.name, current_user.name, current_user.id).order("created_at DESC")
      erb :"donations/index"
    else
      redirect("/login")
    end
  end

  get '/donations/create' do
    @skus = Sku.where("user_id <> ? AND need = ?", current_user.id, "supplier").order("created_at DESC")  #for the select populate
    @providers = User.where("id <> ?", current_user.id).order("created_at DESC")
    @donation = Donation.new
    erb :"donations/create"
  end

    post '/donations' do
    @donation = Donation.new(params[:donation].merge(user_id: current_user.id))
      if @donation.save
        redirect 'donations/ok'
      else
        session[:error] = @donation.errors.messages
        redirect 'donations/create'
      end
    end

  get '/donations/ok' do
    erb :"donations/ok"  
  end
  
  get "/donations/:id" do
    @donation = Donation.find(params[:id])
    erb :"donations/view"
  end

  #  post '/trades/:id' do
  #    @trade = Trade.find(params[:id])
  #    @trade.update(params[:trade])
  #    redirect '/trades'
  #   end
 
  #   get '/trades/:id/del' do
  #   if current_user
  #     trade = Trade.find(params[:id])
  #     trade.destroy
  #     redirect ("/trades")
  #   else
  #     redirect("/login")
  #   end
  #   end
######### NAV LINK CONTROLLERS ##############################################

  get '/about' do
    erb :about
  end

  get '/intro' do
    erb :intro, :layout => false
  end

 #  get '/notif' do
 #   "no messages!"
  #end

  get '/metrics' do
    erb :metrics
  end

  get '/log' do
    erb :log
  end

  # for Google webmaster
  get '/google0ee0d5eabec02fad.html' do
    File.read(File.join('public', 'google0ee0d5eabec02fad.html'))
  end

  get '/json' do
  content_type :json
  { :key1 => 'value1', :key2 => 'value2' }.to_json
end
  
end

class User < ActiveRecord::Base
  has_secure_password
  validates :name, presence: true, uniqueness: true
  validates :email, format: { with: /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\z/i, on: :create }
  validates :address, presence: true
  has_many :skus
end

class Sku < ActiveRecord::Base
  validates :name, presence: true #, uniqueness: true
  validates :need, presence: true
#  validates :quantity, presence: true #q is not needed for needs
#  add_reference :users, :course, index: true
#  validates :user_id, 
  belongs_to :user

def self.search(search)
  # where("name like :name", :name => "#{search}") 
  #where("name like :pat", :pat => "%#{search}%") 
  where("name like ?", "%#{search}%")
end

end

class Service < ActiveRecord::Base
  validates :name, presence: true, uniqueness: true
  belongs_to :user
end

class Trade < ActiveRecord::Base
  validates :trademethod, presence: true
  belongs_to :user
end

class Donation < ActiveRecord::Base
  belongs_to :user
end
