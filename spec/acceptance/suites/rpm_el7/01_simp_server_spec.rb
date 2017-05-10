# This test attempts to set up two repos,
# 1) the simp repo which contains all the puppet modules for a simp deployment
# 2) the dependancy repo that contains rpm used by simp.
#
# Use the following ENV variables to configure the test:
#
# BEAKER_repo
#     cloud   - the test will use the package cloud repos
#     manual  - the test will use the repos you have configured in the data
#               this is not configured yet.
#     default - If no environment variable are set it will attempt to use the files created by the iso
#               build. These are
#                 * The tarball in the DVD_Overlay directory
#                 * The packages downloaded to the yum_data/packages directory
#
# BEAKER_reponame
#     This is used by 'cloud' set up to determine which package cloud
#     repos to use.  It defaults to 6_X.
#
# BEAKER_release_tarball
#     This can be used to override the simp libraries with either cloud or default.
#     It should be either
#        - a url pointing to a tar ball to be downloaded (http: or https:).
#        - a full path to a tarball located on the server running the tests.
#
require 'spec_helper_rpm'
require 'erb'
require 'pathname'

test_name 'puppetserver via rpm'

# Find a release tarball
def configure_repos(host)
  tarball = ENV['BEAKER_release_tarball']
  case ENV['BEAKER_repo']
  when 'cloud'
    # Uses package cloud for everything.  Currently defaults to using 6_X repos
    # Set BEAKER_simp_repo version to point to a different package cloud repo.
    if tarball
      tarball_yumrepos(host,get_tarball(tarball))
    else
      set_packagecloud_simprepo(host)
    end
    set_packagecloud_deprepo(host)
  when 'manual'
    warn("Using repos manually configured in spec data")
    # assumes you have set up repos in the spec data
  else
    #if simp not built, copies tar ball over and points to packagecloud for deps.
    if Dir.exists?('build/distributions/CentOS/7/x86_64/yum_data/packages')
      warn("Creating Dependancy repo from package file in build directory")
      create_deprepo_from_packagesdir(master,'build/distributions/CentOS/7/x86_64/yum_data/packages')
    else
      warn('='*72)
      warn('No packages directory')
      warn('='*72)
    end
    tarball = get_tarball(tarball)
    tarball_yumrepos(host, tarball)
  end
end

def configure_repo_agent(host,puppetserver)
# Not calling this at this time.  Just installing agent from puppet
 case ENV['BEAKER_repo']
  when 'cloud'
    warn("Using package cloud repo for dependancies")
    set_packagecloud_deprepo(master)
  when 'manual'
    warn("Using Manual Repo on client")
    # assumes you have set up repos in the spec data
  else
    create_deprepo_from_packagesdir(master,'build/distributions/CentOS/7/x86_64/yum_data/packages')
  end
end

def set_packagecloud_deprepo(host)
  reponame = find_reponame
  on(host, "curl -s https://packagecloud.io/install/repositories/simp-project/#{reponame}_Dependencies/script.rpm.sh | bash")
  warn("Creating SIMP repo from package cloud version: #{reponame}")
end

def set_packagecloud_simprepo(host)
  reponame = find_reponame
  on(host, "curl -s https://packagecloud.io/install/repositories/simp-project/#{reponame}/script.rpm.sh | bash")
  warn("Creating Depandancy repo from package cloud version: #{reponame}")
end

def find_reponame
# Sets the version for the package cloud repos.
# Defaults to 6_X if BEAKER_reponame is not set.
  reponame = ENV['BEAKER_reponame']
  reponame ||= '6_X'
  warn("Using SIMP reponame #{reponame}")
  reponame
end

def create_deprepo_from_packagesdir(host,depdir)
#  This copies rpms from packages directory to the host and creates a repo
#  The question is is this shared out by apache or do I have to set up something?
  on(host,'mkdir -p /var/www/yum/SIMP/x86_64')
  rsync_to(host,depdir,'/var/www/yum/SIMP/x86_64')
  host.install_package('createrepo')
  on(host, 'createrepo -q -p /var/www/yum/SIMP/x86_64')
  on(host,'chmod go+rX /var/www/yum/SIMP')
  create_remote_file(host, '/etc/yum.repos.d/simp-deps.repo', <<-EOF.gsub(/^\s+/,'')
  [simp-deps]
     name=Dependancy repo from packages.yaml
     baseurl=file:///var/www/yum/SIMP/x86_64
     enabled=1
     gpgcheck=0
     repo_gpgcheck=0
     EOF
  )
  on(host, 'yum makecache')
end

def get_tarball(tarball)
  #This will download the tarball if the tarball is an url
  #if tarball is empty it will point it to the tarball
  #in the build directory.
  if tarball =~ /https:/ or tarball =~ /http:/
    tarball = download_tarball(tarball)
  else
    tarball ||Dir.glob('build/distributions/CentOS/7/x86_64/DVD_Overlay/SIMP*.tar.gz')[0]
  end
  tarball
end

def download_tarball(tarurl)
  warn("Downloading tarball from #{tarurl}")
  filename = 'SIMP-tarball-x86_64.tar.gz'
  require 'net/http'
  Dir.exists?("spec/fixtures") || Dir.mkdir("spec/fixtures")
  File.write("spec/fixtures/#{filename}", Net::HTTP.get(URI.parse(tarurl)))
  tarball =  "spec/fixtures/#{filename}"
  warn("Tarball downloaded from #{tarurl} and copied to spec/fixtures/#{filename}")
  tarball
end

def tarball_yumrepos(host, tarball)
#This takes a tarball location and copies the data to the hosts
#and creates a repo from it.
#
# Check if the location provided is url, if so download it to spec directory
# and point to the dowloaded file
  if File.exists?(tarball)
    warn("Found Tarball: #{tarball}")

    scp_to(host, tarball, '/root/')
    tarball_basename = File.basename(tarball)
    on(host, "mkdir -p /var/www && cd /var/www && tar xzf /root/#{tarball_basename}")
    host.install_package('createrepo')
    on(host, 'createrepo -q -p /var/www/SIMP/noarch')
    create_remote_file(host, '/etc/yum.repos.d/simp_tarball.repo', <<-EOF.gsub(/^\s+/,'')
      [simp-tarball]
      name=Tarball repo
      baseurl=file:///var/www/SIMP/noarch
      enabled=1
      gpgcheck=0
      repo_gpgcheck=0
      EOF
    )
    on(host, 'yum makecache')
  else
    warn('='*72)
    warn("ERROR:  Tarball #{tarball} does not exist")
    warn('='*72)
  end
end


describe 'install SIMP via rpm' do

  masters = hosts_with_role(hosts, 'master')
  agents  = hosts_with_role(hosts, 'agent')
  let(:domain)      { fact_on(master, 'domain') }
  let(:master_fqdn) { fact_on(master, 'fqdn') }

  hosts.each do |host|
    it 'should set the root password' do
      on(host, "sed -i 's/enforce_for_root//g' /etc/pam.d/*")
      on(host, 'echo password | passwd root --stdin')
    end
  end

  context 'master' do
    let(:simp_conf_template) { File.read(File.open('spec/acceptance/suites/rpm_el7/files/simp_conf.yaml.erb')) }
    masters.each do |master|
      it 'should set up SIMP repositories' do
        master.install_package('epel-release')
        configure_repos(master)
        on(master, 'yum makecache')
      end

      it 'should install simp' do
        master.install_package('simp-adapter-foss')
        master.install_package('simp')
      end

      it 'should run simp config' do
        # grub password: H.SxdcuyF56G75*3ww*HF#9i-eDM3Dp5
        # ldap root password: Q*AsdtFlHSLp%Q3tsSEc3vFbFx5Vwe58
        create_remote_file(master, '/root/simp_conf.yaml', ERB.new(simp_conf_template).result(binding))
        on(master, 'simp config -a /root/simp_conf.yaml --quiet --skip-safety-save')
      end

      it 'should provide default hieradata to make beaker happy' do
        create_remote_file(master, '/etc/puppetlabs/code/environments/simp/hieradata/default.yaml', {
          'sudo::user_specifications' => {
            'vagrant_all' => {
              'user_list' =>  ['vagrant'],
              'cmnd'      =>  ['ALL'],
              'passwd'    =>  false,
            },
          },
          'pam::access::users' => {
            'defaults' => {
              'origins'    => ['ALL'],
              'permission' =>  '+'
            },
            'vagrant' => nil
          },
          'ssh::server::conf::permitrootlogin'    =>  true,
          'ssh::server::conf::authorizedkeysfile' =>  '.ssh/authorized_keys',
          # The following settings are because $server_facts['serverip'] is
          # incorrect in a beaker/vagrant (mutli-interface) environment
          'simp::puppet_server_hosts_entry'       => false,
          'simp::rsync_stunnel'                   => master_fqdn,
          # Make sure puppet doesn't run (hopefully)
          'pupmod::agent::cron::minute'           => '0',
          'pupmod::agent::cron::hour'             => '0',
          'pupmod::agent::cron::weekday'          => '0',
          'pupmod::agent::cron::month'            => '1',
          }.to_yaml
        )
      end
      it 'should enable autosign' do
        on(master, 'puppet config --section master set autosign true')
      end

      it 'should run simp bootstrap' do
        # Remove the lock file because we've already added the vagrant user stuff
        on(master, 'rm -f /root/.simp/simp_bootstrap_start_lock')

        on(master, 'simp bootstrap --no-verbose -u --remove_ssldir > /dev/null')
      end

      it 'should reboot the host' do
        master.reboot
        sleep(240)
      end
      it 'should have puppet runs with no changes' do
        on(master, '/opt/puppetlabs/bin/puppet agent -t', :acceptable_exit_codes => [0,2,4,6])
        on(master, '/opt/puppetlabs/bin/puppet agent -t', :acceptable_exit_codes => [0] )
      end
      it 'should generate agent certs' do
        togen = []
        agents.each do |agent|
          togen << agent.hostname + '.' + domain
        end
        create_remote_file(master, '/var/simp/environments/production/FakeCA/togen', togen.join("\n"))
        on(master, 'cd /var/simp/environments/production/FakeCA; ./gencerts_nopass.sh')
      end
    end
  end

  # context 'classify nodes' do
  # end

  context 'agents' do
    agents.each do |agent|
      it 'should install the agent' do
        if agent.host_hash[:platform] =~ /el-7/
          agent.install_package('http://yum.puppetlabs.com/puppetlabs-release-pc1-el-7.noarch.rpm')
        else
          agent.install_package('http://yum.puppetlabs.com/puppetlabs-release-pc1-el-6.noarch.rpm')
          # the portreserve service will fail unless something is configured
          on(agent, 'mkdir -p /etc/portreserve')
          on(agent, 'echo rndc/tcp > /etc/portreserve/named')
        end
        agent.install_package('epel-release')
        agent.install_package('puppet-agent')
        agent.install_package('net-tools')
        configure_repo_agent(agent, master_fqdn)
      end
      it 'should run the agent' do
        # require 'pry';binding.pry if fact_on(agent, 'hostname') == 'agent'
        on(agent, "/opt/puppetlabs/bin/puppet agent -t --ca_port 8141 --masterport 8140 --server #{master_fqdn}", :acceptable_exit_codes => [0,2,4,6])
        on(agent, '/opt/puppetlabs/bin/puppet agent -t', :acceptable_exit_codes => [0,2,4,6])
        agent.reboot
        sleep(240)
        on(agent, '/opt/puppetlabs/bin/puppet agent -t', :acceptable_exit_codes => [0,2])
      end
      it 'should be idempotent' do
        sleep(30)
        on(agent, '/opt/puppetlabs/bin/puppet agent -t', :acceptable_exit_codes => [0])
      end
    end
  end

end
