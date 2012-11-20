#!/usr/bin/env ruby

require 'optparse'
require 'logger'
require 'mcollective'
require 'json'

$:.push( File.join( File.dirname(__FILE__), 'lib' ) )
require 'zabbixclient'

options = {}
optparse = OptionParser.new do |opts|

    options[:zabbix_api_url] = 'http://localhost/zabbix/api_jsonrpc.php'
    opts.on('z', '--zabbix-api-url url', 'JSON-RPC endpoint for zabbix server') do |u|
        options[:zabbix_api_url] = u
    end

    options[:zabbix_user] = 'Admin'
    opts.on('u', '--zabbix-user user', 'Zabbix API username') do |u|
        options[:zabbix_user] = u
    end

    options[:zabbix_pass] = 'zabbix'
    opts.on('p', '--zabbix-pass pass', 'Zabbix API password') do |p|
        options[:zabbix_pass] = p
    end

    options[:debug] = false
    opts.on('d', '--debug', 'Enable debugging') do
        options[:debug] = true
    end

    options[:noop] = false
    opts.on('n', '--noop', 'Don\'t make changes') do
        options[:noop] = true
    end

end

begin

    optparse.parse!

rescue OptionParser::InvalidOption, OptionParser::MissingArgument

    $stderr.puts $!.to_s
    $stderr.puts optparse
    exit 2

end

log = Logger.new(STDERR)

if options[:debug]
    log.level = Logger::DEBUG
else
    log.level = Logger::INFO
end
log.info( "Connecting to Zabbix RPC service" )

zabbix_client = ZabbixClient.new(
    :url      => options[:zabbix_api_url],
    :user     => options[:zabbix_user],
    :password => options[:zabbix_pass],
    :debug    => true
)

log.info( "Connected and authenticated" )

############################################################################
# Fetch list of zabbix templates

log.info( "Fetching list of zabbix templates" )

zabbix_templates = {}

zabbix_client.request( 'template.get', 
    'search' => '', 
    'output' => 'extend' 
).each do |template|

    log.info( "\tName: #{template['name']} ID: #{template['templateid']}" )
    zabbix_templates[ template['name'] ] = template['templateid']

end

# We're going to build a big nasty hash of zabbix and mcollective data
# because apparently I still think like a Perl engineer.  It seems this
# dirty bit of Ruby is necessary to allow them to be anonymously built.
#
nested_hash = lambda {|hash, key| hash[key] = Hash.new(&nested_hash)}
hosts = Hash.new(&nested_hash)


############################################################################
# Iterate through zabbix hosts

zabbix_client.request( 'host.get', 
    'search' => '', 
    'output' => 'extend' 
).each do |host|

    log.info( "Host: #{host['name']}, ID: #{host['hostid']}" )

    # Iterate through hostinterfaces, looking for zabbix agent type
    #  interfaces.
    #
    #  I'm not sure how we should handle multiple interfaces here
    #   but it seems a safe assumption that there will only be one
    #   agent type interface per machine.
    
    zabbix_client.request( 'hostinterface.get',
        'hostids' => host['hostid'], 
        'output'  => 'extend'
    ).each do |interface|

        next unless interface['type'] == "1" # skip non-Zabbix agent interfaces

        log.info( "\tIP: #{interface['ip']}" )
        hosts[ host['name'] ][:zabbix][:ip] = interface['ip']

    end

    hosts[ host['name'] ][:zabbix][:hostid]    = host['hostid']
    hosts[ host['name'] ][:zabbix][:templates] = []

    # Iterate through this host's templates

    zabbix_client.request(
        'template.get',
        'search'  => '',
        'output'  => 'extend',
        'hostids' => host['hostid']
    ).each do |template|

        log.info( "\tTemplate: #{template['name']}" )
        hosts[ host['name'] ][:zabbix][:templates].push( template['name'] )

    end

end

############################################################################
# Iterate through MCollective hosts

include MCollective::RPC

mc = rpcclient("rpcutil", :debug => true)
mc.progress = false

mc.discover.sort.each do |host|

    # MCollective returns FQDN name, and we probably want to use the short
    #  form name in zabbix.
    
    short_hostname = host.split('.').first

    log.info("Host: #{short_hostname} (#{host})")

    # Get inventory details for each host
    inventory = mc.custom_request( "inventory", {}, host,
        { "identity" => host }
    ).first

    # XXX using the ipaddress fact is probably the wrong thing to do here
    # We should take an 'admin interface range' CIDR from the commandline
    #  and use the address matching that instead.
    
    log.info("\tIP #{inventory[:data][:facts]['ipaddress']}")

    hosts[ short_hostname ][:mcollective][:ip]      = inventory[:data][:facts]['ipaddress']
    hosts[ short_hostname ][:mcollective][:classes] = inventory[:data][:classes]

end

mc.disconnect

############################################################################
# Rationalise the two datasets

hosts.each do |host,data|

    ###### Condition 1 #############################################
    #
    # Hosts that are found by mcollective but that aren't in zabbix
    #  should be added.
    
    if data.has_key?(:mcollective) and !data.has_key?(:zabbix)

        log.info( "Host #{host} found by mcollective but not in zabbix" )

        # If mcollective finds a host, but zabbix doesn't list one by
        #  that name, we're going to add it.

        # Iterate through the classes reported by mcollective for this
        #  host. If the class name matches the name of a zabbix template,
        #  get the ID and add an object to the templates_to_add array.
        #  This will be passed to the zabbix API call.

        templates_to_add = []
        data[:mcollective][:classes].each do |template|
            next unless zabbix_templates.has_key?( template )
            template_id = zabbix_templates[ template ]
            log.debug("\tWill be adding template #{template} ID #{template_id}")
            templates_to_add.push( { 'templateid' => template_id } )
        end

        unless options[:noop]

            # If we're not in --noop mode, create the host with the
            #  zabbix API.  Hosts need at least one interface (for now
            #  we're just adding a Zabbix agent interface), and need
            #  to be in a group.

            resp = zabbix_client.request( 'host.create',
                'host'       => host,
                'interfaces' => [
                    {
                        'type'  => 1,
                        'main'  => 1,
                        'useip' => 1,
                        'ip'    => data[:mcollective][:ip],
                        'dns'   => host,
                        'port'  => '10050'
                    }
                ],
                'groups' => [
                    { 'groupid' => '100100000000002' }
                ],
                'templates' => templates_to_add
            )

            # This call returns the created host id

            new_hostid = resp['hostids'].first

            log.info("Host #{host} added as ID #{new_hostid}")

        end

    end

    ###### Condition 2 #############################################
    # If zabbix contains a host that mcollective knows nothing about
    #  we leave it alone but report it.

    if data.has_key?(:zabbix) and !data.has_key?(:mcollective)

        log.warn( "Host #{host} found in zabbix but not by mcollective" )

    end

    ###### Condition 3 #############################################
    # Hosts in zabbix and mcollective are checked to ensure that 
    #  they are linked with at least the templates they should be
    
    if data.has_key?(:zabbix) and data.has_key?(:mcollective)

        log.info( "Host #{host} in both zabbix and mcollective" )

        templates_to_add = []

        # Iterate through the classes mcollective lists for the host

        data[:mcollective][:classes].each do |template|

            # Ignore any that don't match the name of a zabbix template
            next unless zabbix_templates.has_key?( template )

            log.debug("\tHas mcollective class #{template} matching a zabbix template")

            if data[:zabbix][:templates].index( template )

                # The host in zabbix is already linked to a template with the name
                #  of this class.  We do nothing here.
                #
                log.debug("\tZabbix host already linked to a template for this class")

            else

                # Zabbix shows that although it knows about a template with this class
                #  name, the host in question isn't linked to it.  We add this
                #  template to a list of those that are missing in zabbix.

                log.info("\tZabbix #{host} does not have a template for #{template}")
                templates_to_add.push( { 'templateid' => zabbix_templates[ template ] } )
            end

        end

        if !options[:noop] and templates_to_add.count > 0

            # If we're not running --noop and we found missing templates,
            #  link the zabbix host with these.

            zabbix_client.request( 'template.massadd',
                'templates' => templates_to_add,
                'hosts'     => { 'hostid' => data[:zabbix][:hostid] }
            )
            
        end

    end

end
