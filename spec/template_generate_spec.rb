# frozen_string_literal: true

# rspec spec/
#
# Runs template-generate.sh in a scratch directory with fake qm, ceph, rbd,
# virt-customize and curl first on the PATH. curl serves files from a fixture
# tree keyed by URL, so nothing reaches the network or a hypervisor. gpg, gpgv,
# openssl and the sha*sum tools are real: the signatures are made here with
# throwaway keys, pinned in a scratch keys directory.

require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
SCRIPT = File.join(ROOT, 'template-generate.sh')

RSpec.describe 'template-generate.sh' do
  # One signing key for the whole file: generating keys is the slow part.
  before(:all) do
    @keys_root = Dir.mktmpdir('gm-keys-')
    @gnupg = File.join(@keys_root, 'gnupg')
    FileUtils.mkdir_p(@gnupg, mode: 0o700)
    @pinned = gen_key('Pinned Test Key <pinned@example.invalid>')
    @intruder = gen_key('Intruder <intruder@example.invalid>')
    @rsa = File.join(@keys_root, 'rsa.key')
    system('openssl', 'genrsa', '-out', @rsa, '2048', err: File::NULL, exception: true)
    @rsa_pub = File.join(@keys_root, 'rsa.pem')
    system('openssl', 'rsa', '-in', @rsa, '-pubout', '-out', @rsa_pub, err: File::NULL, exception: true)
  end

  after(:all) do
    system({ 'GNUPGHOME' => @gnupg }, 'gpgconf', '--kill', 'all', err: File::NULL)
    FileUtils.rm_rf(@keys_root)
  end

  def gen_key(uid)
    env = { 'GNUPGHOME' => @gnupg }
    system(env, 'gpg', '--batch', '--quiet', '--passphrase', '', '--quick-gen-key', uid, 'ed25519', 'sign', 'never',
           err: File::NULL, exception: true)
    out, = Open3.capture2(env, 'gpg', '--with-colons', '--list-keys', uid)
    out[/^fpr:+([0-9A-F]{40}):/, 1]
  end

  def sign(fpr, data, sig, armor: false)
    args = ['gpg', '--batch', '--yes', '--quiet', '--local-user', fpr, '--detach-sign', '--output', sig]
    args << '--armor' if armor
    system({ 'GNUPGHOME' => @gnupg }, *args, data, err: File::NULL, exception: true)
  end

  def export_key(fpr, path)
    out, = Open3.capture2({ 'GNUPGHOME' => @gnupg }, 'gpg', '--armor', '--export', fpr)
    File.write(path, out)
  end

  around do |example|
    Dir.mktmpdir('gm-run-') do |dir|
      @dir = dir
      @bin = File.join(dir, 'bin')
      @fix = File.join(dir, 'upstream')
      @iso = File.join(dir, 'iso')
      @base = File.join(dir, 'base')
      @work = File.join(dir, 'work')
      @keys = File.join(dir, 'keys')
      @state = File.join(dir, 'qm.state')
      @log = File.join(dir, 'calls.log')
      [@bin, @fix, @iso, @base, @work, @keys].each { |d| FileUtils.mkdir_p(d) }
      File.write(@state, '')
      install_fakes
      pin_keys
      example.run
    end
  end

  def fake(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  def install_fakes
    fake('ceph', 'exit 0')
    fake('rbd', 'exit 0')
    fake('virt-customize', %(echo "virt-customize $*" >> '#{@log}'))
    # qm keeps "vmid name" lines in a state file.
    fake('qm', <<~SH)
      echo "qm $*" >> '#{@log}'
      st='#{@state}'
      case "$1" in
      list) echo "      VMID NAME   STATUS"; awk '{print "     " $1 " " $2 " stopped"}' "$st" ;;
      status) grep -q "^$2 " "$st"; exit $? ;;
      config) awk -v id="$2" '$1 == id {print "name: " $2}' "$st" ;;
      create) id=$2; while [ $# -gt 0 ]; do [ "$1" = --name ] && echo "$id $2" >> "$st"; shift; done ;;
      destroy) grep -v "^$2 " "$st" > "$st.new"; mv "$st.new" "$st" ;;
      importdisk) echo "unused0: successfully imported disk 'ceph:vm-$2-disk-0'" ;;
      esac
      exit 0
    SH
    # curl serves https://host/path from upstream/host/path, honours -z the way
    # the real one does (no body unless upstream is newer), and keeps -R times.
    fake('curl', <<~SH)
      out=; z=; url=
      while [ $# -gt 0 ]; do
        case "$1" in -o) out=$2; shift ;; -z) z=$2; shift ;; -*) ;; *) url=$1 ;; esac
        shift
      done
      echo "curl $url" >> '#{@log}'
      src='#{@fix}'/"${url#https://}"
      [ -f "$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
      if [ -n "$z" ] && [ ! "$src" -nt "$z" ]; then : > "$out"; exit 0; fi
      cp "$src" "$out" && touch -r "$src" "$out"
    SH
  end

  # The scratch keys directory pins the test key under every name the script
  # uses, and the test RSA key as the Amazon key.
  def pin_keys(fpr = @pinned)
    names = %w[rocky-9 rocky-10 alma-8 alma-9 alma-10 ubuntu-cloud-images arch-boxes]
    names.each { |n| export_key(fpr, File.join(@keys, "#{n}.asc")) }
    FileUtils.cp(@rsa_pub, File.join(@keys, 'amazon-linux-2.pem'))
    der = `openssl pkey -pubin -in #{@rsa_pub} -outform DER`
    File.write(File.join(@keys, 'fingerprints'),
               (names.map { |n| "#{n} #{@pinned}" } + ["amazon-linux-2 #{Digest::SHA256.hexdigest(der)}"]).join("\n") + "\n")
  end

  def upstream(url, content, mtime: Time.now - 60)
    path = File.join(@fix, url.sub(%r{\Ahttps://}, ''))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    File.utime(mtime, mtime, path)
    path
  end

  def csv(*rows)
    File.write(File.join(@work, 'templates.csv'), "#Name,Version,URL,ISO,SHA256\n#{rows.join("\n")}\n")
  end

  def run_gm(env = {}, umask = 0o022)
    base_env = { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'BASEDIR' => @base, 'ISODIR' => @iso,
                 'KEYDIR' => @keys, 'HOME' => @dir, 'GNUPGHOME' => nil, 'INSTANCE' => nil,
                 'NAME_SUFFIX' => nil, 'TARGETS' => nil, 'FORCE_REBUILD' => nil }
    old = File.umask(umask)
    Open3.capture2e(base_env.merge(env), 'sh', SCRIPT, chdir: @work, stdin_data: '')
  ensure
    File.umask(old)
  end

  def created = File.exist?(@log) ? File.readlines(@log, chomp: true).grep(/^qm create /) : []

  ROCKY = 'https://dl.rockylinux.org/pub/rocky/9/images/x86_64/'
  ROCKY_ISO = 'Rocky-9-GenericCloud-Base.latest.x86_64.qcow2'

  # A signed Rocky 9 release: image, CHECKSUM in Rocky's BSD format, and its
  # detached ASCII signature.
  def rocky_release(image: 'rocky image', signer: @pinned, listed: image)
    upstream("#{ROCKY}#{ROCKY_ISO}", image)
    sums = upstream("#{ROCKY}CHECKSUM", "# #{ROCKY_ISO}: #{listed.bytesize} bytes\n" \
                                        "SHA256 (#{ROCKY_ISO}) = #{Digest::SHA256.hexdigest(listed)}\n")
    sign(signer, sums, "#{sums}.asc", armor: true)
    sums
  end

  describe 'signed checksums' do
    it 'builds from an image that matches the checksum its distro signed' do
      rocky_release
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).to be_success, out
      expect(created.first).to start_with('qm create 11800 ')
      expect(File.read(File.join(@iso, ROCKY_ISO))).to eq('rocky image')
    end

    it 'refuses a download whose checksum does not match, and keeps it out of the cache' do
      rocky_release(image: 'tampered', listed: 'the real image')
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).not_to be_success
      expect(out).to match(/checksum mismatch/i)
      expect(created).to be_empty
      expect(Dir.children(@iso)).to be_empty
    end

    it 'refuses a cached image that no longer matches upstream, even when upstream has nothing newer' do
      rocky_release(image: 'rocky image')
      File.write(File.join(@iso, ROCKY_ISO), 'swapped on the share')
      File.utime(Time.now, Time.now, File.join(@iso, ROCKY_ISO))
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).not_to be_success
      expect(out).to match(/checksum mismatch/i)
      expect(created).to be_empty
    end

    it 'refuses a checksum file whose signature does not verify, before downloading the image' do
      sums = rocky_release
      File.write(sums, File.read(sums).sub(/= \h+/, "= #{'0' * 64}"))
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).not_to be_success
      expect(out).to match(/signature/i)
      expect(created).to be_empty
      expect(File.readlines(@log, chomp: true)).not_to include("curl #{ROCKY}#{ROCKY_ISO}")
    end

    it 'refuses a checksum file signed by a key that is not pinned' do
      rocky_release(signer: @intruder)
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).not_to be_success
      expect(created).to be_empty
    end

    it 'refuses a key file that is not the pinned key, even when it verifies the signature' do
      rocky_release(signer: @intruder)
      export_key(@intruder, File.join(@keys, 'rocky-9.asc'))
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).not_to be_success
      expect(out).to match(/pinned/i)
      expect(created).to be_empty
    end

    it 'refuses when upstream publishes no checksum file' do
      upstream("#{ROCKY}#{ROCKY_ISO}", 'rocky image')
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      _out, status = run_gm
      expect(status).not_to be_success
      expect(created).to be_empty
    end

    it 'verifies Ubuntu against SHA256SUMS and its binary signature' do
      url = 'https://cloud-images.ubuntu.com/noble/current/'
      upstream("#{url}noble-server-cloudimg-amd64.img", 'noble')
      sums = upstream("#{url}SHA256SUMS", "#{Digest::SHA256.hexdigest('noble')} *noble-server-cloudimg-amd64.img\n")
      sign(@pinned, sums, "#{sums}.gpg")
      csv('Ubuntu,2404,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).to be_success, out
      expect(created.first).to start_with('qm create 12500 ')
    end

    it 'verifies Alma against CHECKSUM in GNU format' do
      url = 'https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/'
      iso = 'AlmaLinux-9-GenericCloud-latest.x86_64.qcow2'
      upstream("#{url}#{iso}", 'alma')
      sums = upstream("#{url}CHECKSUM", "#{Digest::SHA256.hexdigest('other')}  other.qcow2\n" \
                                        "#{Digest::SHA256.hexdigest('alma')}  #{iso}\n")
      sign(@pinned, sums, "#{sums}.asc", armor: true)
      csv('Alma,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm
      expect(status).to be_success, out
      expect(created.first).to start_with('qm create 17200 ')
    end

    it 'verifies Arch against the signature over the image itself' do
      url = 'https://geo.mirror.pkgbuild.com/images/latest/'
      iso = 'Arch-Linux-x86_64-cloudimg.qcow2'
      img = upstream("#{url}#{iso}", 'arch')
      upstream("#{url}#{iso}.SHA256", "#{Digest::SHA256.hexdigest('arch')}  #{iso}\n")
      sign(@pinned, img, "#{img}.sig")
      csv("Arch,1,#{url},#{iso},")
      out, status = run_gm
      expect(status).to be_success, out
      expect(created.first).to start_with('qm create 14100 ')
    end

    it 'refuses Arch when the image signature does not verify' do
      url = 'https://geo.mirror.pkgbuild.com/images/latest/'
      iso = 'Arch-Linux-x86_64-cloudimg.qcow2'
      img = upstream("#{url}#{iso}", 'arch')
      upstream("#{url}#{iso}.SHA256", "#{Digest::SHA256.hexdigest('arch')}  #{iso}\n")
      sign(@intruder, img, "#{img}.sig")
      csv("Arch,1,#{url},#{iso},")
      _out, status = run_gm
      expect(status).not_to be_success
      expect(created).to be_empty
    end

    it 'verifies Amazon Linux against its RSA-signed SHA256SUMS' do
      url = 'https://cdn.amazonlinux.com/os-images/2.0.1/kvm/'
      iso = 'amzn2.qcow2'
      upstream("#{url}#{iso}", 'amzn')
      sums = upstream("#{url}SHA256SUMS", "#{Digest::SHA256.hexdigest('amzn')}  #{iso}\n")
      system('openssl', 'dgst', '-sha256', '-sign', @rsa, '-out', "#{sums}.RSASSA_PKCS1_V1_5_SHA_256", sums,
             exception: true)
      csv("AmazonLinux,2,#{url},#{iso},")
      out, status = run_gm
      expect(status).to be_success, out
      expect(created.first).to start_with('qm create 15100 ')
    end

    it 'checks Debian against its SHA512SUMS, which Debian does not sign' do
      url = 'https://cdimage.debian.org/images/cloud/bookworm/latest/'
      iso = 'debian-12-genericcloud-amd64.qcow2'
      upstream("#{url}#{iso}", 'debian')
      upstream("#{url}SHA512SUMS", "#{Digest::SHA512.hexdigest('tampered')}  #{iso}\n")
      csv("Debian,12,#{url},#{iso},")
      out, status = run_gm
      expect(status).not_to be_success
      expect(out).to match(/checksum mismatch/i)
      expect(created).to be_empty
    end
  end

  describe 'pinned checksums' do
    let(:url) { 'https://yum.oracle.com/templates/OracleLinux/OL9/u8/x86_64/' }
    let(:iso) { 'OL9U8_x86_64-kvm-b293.qcow2' }

    it 'builds Oracle from the SHA256 pinned in templates.csv' do
      upstream("#{url}#{iso}", 'oracle')
      csv("Oracle,9,#{url},#{iso},#{Digest::SHA256.hexdigest('oracle')}")
      out, status = run_gm
      expect(status).to be_success, out
      expect(created.first).to start_with('qm create 18300 ')
    end

    it 'refuses Oracle when the image does not match the pin' do
      upstream("#{url}#{iso}", 'oracle')
      csv("Oracle,9,#{url},#{iso},#{Digest::SHA256.hexdigest('something else')}")
      _out, status = run_gm
      expect(status).not_to be_success
      expect(created).to be_empty
    end

    it 'refuses an image with neither a published checksum nor a pin' do
      File.write(File.join(@iso, 'rhel.qcow2'), 'rhel')
      csv('RedHat,9,NULL,rhel.qcow2,')
      out, status = run_gm
      expect(status).not_to be_success
      expect(out).to include('templates.csv')
      expect(created).to be_empty
    end
  end

  it 'skips a row with no image (Windows) without failing the run' do
    csv('Windows,2022,NULL,')
    out, status = run_gm
    expect(status).to be_success, out
    expect(out).to include('No ISO definition')
    expect(created).to be_empty
  end

  describe 'the ISO cache' do
    it 'writes images 0644 whatever the umask, and never world-writable' do
      rocky_release
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm({}, 0o000)
      expect(status).to be_success, out
      expect(File.stat(File.join(@iso, ROCKY_ISO)).mode & 0o777).to eq(0o644)
    end
  end

  describe 'TARGETS' do
    def ubuntu_release
      url = 'https://cloud-images.ubuntu.com/noble/current/'
      upstream("#{url}noble-server-cloudimg-amd64.img", 'noble')
      sums = upstream("#{url}SHA256SUMS", "#{Digest::SHA256.hexdigest('noble')} *noble-server-cloudimg-amd64.img\n")
      sign(@pinned, sums, "#{sums}.gpg")
    end

    it 'builds only the listed templates, each at its VMID, naming a non-zero instance -v<n+1>' do
      rocky_release
      ubuntu_release
      csv('Rocky,9,DYNAMIC,DYNAMIC,', 'Ubuntu,2404,DYNAMIC,DYNAMIC,', 'Debian,12,https://x.invalid/,d.qcow2,')
      out, status = run_gm('TARGETS' => 'rocky-9=11800 ubuntu-2404=12501')
      expect(status).to be_success, out
      expect(created.map { |c| c.split[2..4] }).to contain_exactly(
        %w[11800 --memory 1024], %w[12501 --memory 1024]
      )
      expect(File.read(@state)).to include('12501 template-Ubuntu-2404-v2', '11800 template-Rocky-9')
      expect(File.read(@state)).not_to include('12500')
    end

    it 'skips a listed template that already exists and builds nothing beside it' do
      File.write(@state, "12501 template-Ubuntu-2404-v2\n")
      csv('Ubuntu,2404,DYNAMIC,DYNAMIC,')
      out, status = run_gm('TARGETS' => 'ubuntu-2404=12501')
      expect(status).to be_success, out
      expect(created).to be_empty
    end

    it 'fails a target with no row in templates.csv' do
      csv('Rocky,9,DYNAMIC,DYNAMIC,')
      out, status = run_gm('TARGETS' => 'oracle-9=18301')
      expect(status).not_to be_success
      expect(out).to include('oracle-9')
      expect(created).to be_empty
    end

    it 'fails a target whose VMID is not one of its template slots' do
      csv('Ubuntu,2404,DYNAMIC,DYNAMIC,')
      out, status = run_gm('TARGETS' => 'ubuntu-2404=11800')
      expect(status).not_to be_success
      expect(out).to include('11800')
      expect(created).to be_empty
    end

    it 'refuses TARGETS together with INSTANCE' do
      csv('Ubuntu,2404,DYNAMIC,DYNAMIC,')
      _out, status = run_gm('TARGETS' => 'ubuntu-2404=12501', 'INSTANCE' => '01', 'NAME_SUFFIX' => '-v2')
      expect(status).not_to be_success
      expect(created).to be_empty
    end
  end

  describe 'the keys in the repo' do
    it 'holds exactly the pinned keys, each matching its pinned fingerprint' do
      dir = File.join(ROOT, 'keys')
      pins = File.readlines(File.join(dir, 'fingerprints'), chomp: true).grep_v(/\A\s*(#|\z)/).to_h(&:split)
      files = Dir.children(dir).reject { |f| f == 'fingerprints' }
      expect(files.map { |f| File.basename(f, '.*') }).to match_array(pins.keys)
      pins.each do |name, fpr|
        asc = File.join(dir, "#{name}.asc")
        if File.exist?(asc)
          out, = Open3.capture2('gpg', '--show-keys', '--with-colons', asc)
          expect(out.scan(/^pub.*\nfpr:+(\h{40}):/).flatten).to eq([fpr]), name
        else
          der = `openssl pkey -pubin -in #{File.join(dir, "#{name}.pem")} -outform DER`
          expect(Digest::SHA256.hexdigest(der)).to eq(fpr), name
        end
      end
    end
  end
end
