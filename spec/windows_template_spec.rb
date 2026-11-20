# frozen_string_literal: true

# rspec spec/windows_template_spec.rb
#
# The Packer build for the Windows templates (packer-windows.sh and
# packer/windows). It runs `packer fmt -check` and `packer validate` with a
# TEST-NET URL and a dummy token, so nothing reaches Proxmox, and checks the
# files for the properties a template must have: no credentials, cloudbase-init
# reading the config drive only, WinRM gone, and every ISO and MSI pinned.
# packer-windows.sh runs with fake packer, curl, and openssl first on the
# PATH. `packer init` must have installed the pinned proxmox plugin once.

require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__) unless defined?(ROOT)
WIN = File.join(ROOT, 'packer/windows')
BUILD = File.join(ROOT, 'packer-windows.sh')

RSpec.describe 'the Windows template build' do
  def read(rel) = File.read(File.join(WIN, rel))
  def hcl = read('windows.pkr.hcl')

  # calculate_base_id, taken from template-generate.sh as packer-windows.sh takes it.
  def base_id(name, version)
    fn = File.read(File.join(ROOT, 'template-generate.sh'))[/^calculate_base_id\(\) \{\n.*?^\}\n/m]
    out, status = Open3.capture2('bash', '-c', "#{fn}\ncalculate_base_id \"$1\" \"$2\"", '_', name, version)
    raise out unless status.success?

    Integer(out.strip)
  end

  def validate_env = { 'PROXMOX_URL' => 'https://192.0.2.10:8006/api2/json', 'PROXMOX_USERNAME' => 'spec@pve!spec',
                       'PROXMOX_TOKEN' => 'not-a-token', 'PKR_VAR_build_password' => 'NotARealPassword1', 'PACKER_LOG' => nil }

  describe 'packer' do
    it 'is formatted' do
      out, status = Open3.capture2e('packer', 'fmt', '-check', '-recursive', WIN)
      expect(status).to be_success, out
    end

    %w[2022 2025].each do |v|
      it "validates with the #{v} var file" do
        # Until the licence gate pins the ISO, validate with a stand-in pin.
        stand_in = read("#{v}.pkrvars.hcl").include?('PENDING') ? ['-var', "iso_checksum=sha256:#{'0' * 64}", '-var', 'iso_url=https://192.0.2.1/x.iso'] : []
        out, status = Open3.capture2e(validate_env, 'packer', 'validate', "-var-file=#{File.join(WIN, "#{v}.pkrvars.hcl")}", *stand_in, WIN)
        expect(status).to be_success, out
      end
    end
  end

  describe 'VMIDs' do
    it 'puts Windows 2022 at 2110 and 2025 at 2120' do
      expect(base_id('Windows', '2022')).to eq(2110)
      expect(base_id('Windows', '2025')).to eq(2120)
    end

    %w[2022 2025].each do |v|
      it "builds #{v} at ten times its base id, as template-Windows-#{v}" do
        vars = read("#{v}.pkrvars.hcl")
        expect(vars[/^vm_id\s*=\s*(\d+)/, 1].to_i).to eq(base_id('Windows', v) * 10)
        expect(vars[/^template_name\s*=\s*"([^"]+)"/, 1]).to eq("template-Windows-#{v}")
      end
    end
  end

  describe 'credentials' do
    let(:files) { Dir.glob(File.join(WIN, '**', '*')).select { |f| File.file?(f) } }

    it 'references a password only as the build password' do
      hits = files.flat_map do |f|
        File.readlines(f).each_with_index.select { |l, _| l.gsub(/1password/i, '').match?(/password/i) }.map { |l, i| "#{File.basename(f)}:#{i + 1}: #{l.strip}" }
      end
      allowed = [
        /\Awindows\.pkr\.hcl:\d+: variable "build_password" \{\z/,
        /\Awindows\.pkr\.hcl:\d+: description = "The build's Administrator password\./,
        /\Awindows\.pkr\.hcl:\d+: (winrm_password\s*=\s*var\.build_password|"autounattend\.xml".*build_password\s*=\s*var\.build_password.*)\z/,
        /\Aautounattend\.xml\.pkrtpl:\d+: <(AdministratorPassword|Password)>\z/,
        /\Aautounattend\.xml\.pkrtpl:\d+: <\/(AdministratorPassword|Password)>\z/,
        /\Aautounattend\.xml\.pkrtpl:\d+: <Value>\$\{build_password\}<\/Value>\z/,
      ]
      expect(hits.reject { |h| allowed.any? { |a| h.match?(a) } }).to eq([])
      expect(read('answer/autounattend.xml.pkrtpl').scan(/\$\{([a-z_]+)\}/).flatten.uniq.sort).to eq(%w[build_password image_index virtio_os])
    end

    it 'declares the build password sensitive, with no default' do
      block = hcl[/^variable "build_password" \{\n(.*?)^\}/m, 1]
      expect(block).to match(/^\s*sensitive\s*=\s*true$/)
      expect(block).not_to match(/^\s*default\s*=/)
    end

    it 'declares no variable for the Proxmox URL, username, or token, which the plugin reads from the environment' do
      Dir.glob(File.join(WIN, '*.pkr.hcl')).each do |f|
        expect(File.read(f)).not_to match(/^variable "[^"]*(proxmox|user|token)[^"]*"/i)
        expect(File.read(f)).not_to match(/^\s*(proxmox_url|username|token)\s*=/)
      end
    end
  end

  describe 'pins' do
    it 'pins the proxmox plugin and verifies TLS' do
      expect(hcl).to match(/source\s*=\s*"github.com\/hashicorp\/proxmox"\n\s*version\s*=\s*"= \d+\.\d+\.\d+"/)
      expect(hcl).to match(/^\s*insecure_skip_tls_verify\s*=\s*false$/)
    end

    it 'gives every downloaded ISO and MSI a sha256 checksum' do
      checksums = (hcl + read('2022.pkrvars.hcl') + read('2025.pkrvars.hcl')).scan(/checksum\s*=\s*"([^"]*)"/).flatten
      expect(checksums.size).to be >= 3
      expect(hcl.scan(/iso_url\s*=/).size + hcl.scan(/msi_url\s*=/).size).to eq(hcl.scan(/(?:iso|msi)_checksum\s*=/).size)
      checksums.reject { |c| c.include?('var.') || c == 'PENDING' }.each { |c| expect(c).to match(/\Asha256:[0-9a-f]{64}\z/) }
    end

    %w[2022 2025].each do |v|
      it "pins the #{v} Windows ISO by sha256" do
        pending "the licence gate: Tony accepts the Evaluation Center terms and approves the #{v} ISO URL" if read("#{v}.pkrvars.hcl").include?('PENDING')
        expect(read("#{v}.pkrvars.hcl")[/^iso_checksum\s*=\s*"([^"]+)"/, 1]).to match(/\Asha256:[0-9a-f]{64}\z/)
        expect(read("#{v}.pkrvars.hcl")[/^iso_url\s*=\s*"([^"]+)"/, 1]).to start_with('https://')
      end
    end
  end

  describe 'cloudbase-init' do
    let(:conf) { read('cloudbase-init/cloudbase-init.conf') }
    def setting(text, key) = text[/^#{key}\s*=\s*(.*)$/, 1]

    it 'logs without debug' do
      expect(setting(conf, 'debug')).to eq('false')
      expect(setting(read('cloudbase-init/cloudbase-init-unattend.conf'), 'debug')).to eq('false')
    end

    it 'reads the config drive only' do
      expect(setting(conf, 'metadata_services')).to eq('cloudbaseinit.metadata.services.configdrive.ConfigDriveService')
    end

    it 'runs exactly the network, volume, and user-data plugins' do
      expect(setting(conf, 'plugins').split(',').map { |p| p.strip.split('.').last }).to eq(%w[NetworkConfigPlugin ExtendVolumesPlugin UserDataPlugin])
      %w[CreateUserPlugin SetUserPasswordPlugin SetUserSSHPublicKeysPlugin SetHostNamePlugin WinRMListenerPlugin
         WinRMCertificateAuthPlugin].each do |p|
        expect(Dir.glob(File.join(WIN, 'cloudbase-init', '*.conf')).map { |f| File.read(f) }.join).not_to include(p)
      end
    end

    it 'installs the pinned MSI silently, as LocalSystem, and copies the three config files over its own' do
      script = read('scripts/install-cloudbase-init.ps1')
      expect(script).to include('RUN_SERVICE_AS_LOCAL_SYSTEM=1', '/qn', 'Get-FileHash')
      %w[cloudbase-init.conf cloudbase-init-unattend.conf Unattend.xml].each { |f| expect(script).to include(f) }
    end
  end

  describe 'finalise.ps1' do
    let(:script) { read('scripts/finalise.ps1') }

    it 'removes the answer files' do
      expect(script).to include('C:\\Windows\\Panther\\unattend.xml', 'C:\\Windows\\Panther\\Unattend\\*')
    end

    it 'removes WinRM: its listeners, the firewall rule Packer opened, and the service' do
      expect(script).to include('Remove-Item -Path WSMan:\\Localhost\\Listener\\* -Recurse',
                                "Remove-NetFirewallRule -DisplayName 'Packer WinRM'",
                                'Set-Service -Name WinRM -StartupType Disabled')
      expect(read('answer/autounattend.xml.pkrtpl')).to include('Packer WinRM')
    end

    it 'disables the built-in Administrator by its SID, and restricts the cloudbase-init log directory' do
      expect(script).to include("Get-LocalUser | Where-Object { $_.SID -like '*-500' } | Disable-LocalUser")
      expect(script).to match(/icacls .*Cloudbase-Init\\log.*\/inheritance:r.*SYSTEM.*Administrators/)
    end

    it 'ends with sysprep generalising to OOBE and shutting down, with cloudbase-init\'s Unattend.xml' do
      last = script.lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') || l == '}' }.grep(/sysprep\.exe/i).last
      expect(last).to match(%r{sysprep\.exe.*/generalize /oobe /shutdown /unattend:.*Cloudbase-Init\\conf\\Unattend\.xml})
      seal = script[/\$seal = \{\n(.*?)^\}/m, 1].lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
      expect(seal.last).to match(/sysprep/)
    end
  end

  describe 'packer-windows.sh' do
    let(:text) { File.read(BUILD) }

    it 'builds with -on-error=cleanup and the version\'s var file only, never setting PACKER_LOG' do
      builds = text.lines.grep(/packer build/)
      expect(builds.size).to eq(1)
      expect(builds.first).to include('-on-error=cleanup', '-var-file="packer/windows/${version}.pkrvars.hcl"')
      expect(text.scan(/-var(?:-file)?[ =]/).size).to eq(1)
      expect(text).not_to match(/PACKER_LOG\s*=\s*[^\s"']|export PACKER_LOG/)
    end

    it 'is shellcheck clean' do
      out, status = Open3.capture2e('shellcheck', BUILD)
      expect(status).to be_success, out
    end

    describe 'run' do
      around do |example|
        Dir.mktmpdir('gm-packer-') do |dir|
          @dir = dir
          @bin = File.join(dir, 'bin')
          FileUtils.mkdir_p(@bin)
          @log = File.join(dir, 'calls.log')
          example.run
        end
      end

      def fake(name, body)
        path = File.join(@bin, name)
        File.write(path, "#!/usr/bin/env bash\n#{body}\n")
        File.chmod(0o755, path)
      end

      def calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []

      # resources: what the API's cluster resource list holds, as [vmid, name, template].
      def run_build(*args, env: {}, resources: [])
        data = resources.map { |id, name, tmpl| %({"vmid":#{id},"name":"#{name}","node":"ankh","type":"qemu","template":#{tmpl ? 1 : 0}}) }
        gone = File.join(@dir, 'deleted')
        fake('curl', <<~SH)
          cfg=$(cat)
          echo "curl args=$* stdin=${cfg//$'\\n'/|}" >> #{@log}
          case "$cfg" in *DELETE*) touch #{gone}; echo '{"data":"UPID"}'; exit 0 ;; esac
          if [ -f #{gone} ]; then echo '{"data":[]}'; else echo '{"data":[#{data.join(',')}]}'; fi
        SH
        fake('packer', %(echo "packer args=$* log=${PACKER_LOG:-unset} pw=${#PKR_VAR_build_password}" >> #{@log}))
        base = { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'PROXMOX_URL' => 'https://192.0.2.10:8006/api2/json',
                 'PROXMOX_USERNAME' => 'spec@pve!spec', 'PROXMOX_TOKEN' => 'pve-token-value', 'PACKER_LOG' => nil,
                 'FORCE_REBUILD' => nil, 'CONFIRM_DESTROY' => nil }
        Open3.capture2e(base.merge(env), BUILD, *args)
      end

      it 'refuses a version it has no var file for' do
        out, status = run_build('2019')
        expect(status).not_to be_success
        expect(out).to include('2022 or 2025')
        expect(calls).to be_empty
      end

      it 'builds a missing template with a generated password it never prints' do
        out, status = run_build('2022')
        expect(status).to be_success, out
        build = calls.grep(/^packer args=build/)
        expect(build.size).to eq(1)
        expect(build.first).to include('-on-error=cleanup', '-var-file=packer/windows/2022.pkrvars.hcl', 'log=unset')
        expect(build.first[/pw=(\d+)/, 1].to_i).to be >= 24
        expect(out).not_to match(/pw=|PKR_VAR_build_password=/)
      end

      it 'unsets a PACKER_LOG it was given' do
        run_build('2022', env: { 'PACKER_LOG' => '1' })
        expect(calls.grep(/^packer args=build/).first).to include('log=unset')
      end

      it 'never passes the Proxmox token to curl in its arguments' do
        run_build('2022')
        calls.grep(/^curl/).each { |c| expect(c[/args=(.*) stdin=/, 1]).not_to include('pve-token-value') }
      end

      it 'skips a template that already exists' do
        out, status = run_build('2022', resources: [[21_100, 'template-Windows-2022', true]])
        expect(status).to be_success, out
        expect(out).to include('already exists')
        expect(calls.grep(/^packer args=build/)).to be_empty
      end

      it 'refuses FORCE_REBUILD=true unless CONFIRM_DESTROY names the VMID' do
        [nil, '21200', 'yes'].each do |confirm|
          out, status = run_build('2022', env: { 'FORCE_REBUILD' => 'true', 'CONFIRM_DESTROY' => confirm },
                                          resources: [[21_100, 'template-Windows-2022', true]])
          expect(status).not_to be_success, confirm.inspect
          expect(out).to include('CONFIRM_DESTROY=21100')
        end
        expect(calls.grep(/^packer args=build|-X DELETE|request = "DELETE"/)).to be_empty
      end

      it 'refuses to replace a VMID that holds anything but that exact template' do
        [[21_100, 'template-Windows-2022', false], [21_100, 'dc1', false], [21_100, 'template-windows-2022', true]].each do |vm|
          out, status = run_build('2022', env: { 'FORCE_REBUILD' => 'true', 'CONFIRM_DESTROY' => '21100' }, resources: [vm])
          expect(status).not_to be_success, vm.inspect
          expect(out).to include('21100')
        end
        expect(calls.grep(/^packer args=build/)).to be_empty
      end

      it 'refuses when the template name already exists at another VMID' do
        out, status = run_build('2022', resources: [[91_000, 'template-Windows-2022', true]])
        expect(status).not_to be_success
        expect(out).to include('91000')
        expect(calls.grep(/^packer args=build/)).to be_empty
      end

      it 'with FORCE_REBUILD=true and the right CONFIRM_DESTROY, deletes only that VMID, then builds' do
        out, status = run_build('2022', env: { 'FORCE_REBUILD' => 'true', 'CONFIRM_DESTROY' => '21100' },
                                        resources: [[21_100, 'template-Windows-2022', true]])
        expect(status).to be_success, out
        deletes = calls.grep(/DELETE/)
        expect(deletes.size).to eq(1)
        expect(deletes.first).to include('/nodes/ankh/qemu/21100')
        expect(calls.grep(/^packer args=build/).size).to eq(1)
      end

      it 'refuses to run without the Proxmox credentials in the environment' do
        out, status = run_build('2022', env: { 'PROXMOX_TOKEN' => nil })
        expect(status).not_to be_success
        expect(out).to include('PROXMOX_TOKEN')
        expect(calls).to be_empty
      end
    end
  end
end
