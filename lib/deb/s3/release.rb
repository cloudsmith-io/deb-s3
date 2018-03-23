# -*- encoding : utf-8 -*-
require "tempfile"

class Deb::S3::Release
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :origin
  attr_accessor :suite
  attr_accessor :architectures
  attr_accessor :components
  attr_accessor :cache_control
  attr_accessor :supported_archs
  attr_accessor :acquire_by_hash

  attr_accessor :files
  attr_accessor :policy

  def initialize
    @origin = nil
    @suite = nil
    @codename = nil
    @architectures = []
    @components = []
    @cache_control = ""
    @supported_archs = []
    @acquire_by_hash = true
    @files = {}
    @policy = :public_read
  end

  class << self
    def retrieve(codename, origin=nil, suite=nil, cache_control=nil,
                 acquire_by_hash=true, supported_archs=[])
      if s = Deb::S3::Utils.s3_read("dists/#{codename}/Release")
        rel = self.parse_release(s)
      else
        rel = self.new
        rel.codename = codename
        rel.origin = origin unless origin.nil?
        rel.suite = suite.nil? ? codename : nil
      end
      rel.cache_control = cache_control
      rel.supported_archs = supported_archs
      rel.acquire_by_hash = acquire_by_hash
      rel
    end

    def parse_release(str)
      rel = self.new
      rel.parse(str)
      rel
    end
  end

  def filepath
    "dists/#{@codename}"
  end

  def release_filepath
    "#{self.filepath}/Release"
  end

  def inrelease_filepath
    "#{self.filepath}/InRelease"
  end

  def parse(str)
    parse = lambda do |field|
      value = str[/^#{field}: .*/]
      if value.nil?
        return nil
      else
        return value.split(": ",2).last
      end
    end

    # grab basic fields
    self.codename = parse.call("Codename")
    self.origin = parse.call("Origin") || nil
    self.suite = parse.call("Suite") || nil
    self.architectures = (parse.call("Architectures") || "").split(/\s+/)
    self.components = (parse.call("Components") || "").split(/\s+/)

    # find all the hashes
    str.scan(/^\s+([^\s]+)\s+(\d+)\s+(.+)$/).each do |(hash,size,name)|
      self.files[name] ||= { :size => size.to_i }
      case hash.length
      when 32
        self.files[name][:md5] = hash
      when 40
        self.files[name][:sha1] = hash
      when 64
        self.files[name][:sha256] = hash
      end
    end
  end

  def generate
    template("release.erb").result(binding)
  end

  def write_to_s3(options = {})
    inrelease = options[:inrelease] ||= false

    # validate some other files are present
    if block_given?
      self.validate_others { |f| yield f }
    else
      self.validate_others
    end

    # generate the Release files
    release_tmp = Tempfile.new("Release")
    release_tmp.puts self.generate
    release_tmp.close
    release_mime_type = 'text/plain; charset=UTF-8'

    filepath = inrelease ? self.inrelease_filepath : self.release_filepath
    yield filepath if block_given?

    # sign the file, if necessary
    signing_key = Deb::S3::Utils.signing_key
    if signing_key
      signed_mime_type = 'application/pgp-signature; charset=UTF-8'
      signed_tmp = inrelease ? Tempfile.new("InRelease") : nil
      gpg_binary = Deb::S3::Utils.gpg_binary
      gpg_options = Deb::S3::Utils.gpg_options
      gpg_options += inrelease ? " --clearsign -o #{signed_tmp.path}" : ' -b'
      gpg_key = signing_key != "" ? "--default-key=#{signing_key}" : ""
      gpg_cmd = "#{gpg_binary} -a #{gpg_key} #{gpg_options} #{release_tmp.path}"

      if system(gpg_cmd)
        if inrelease
          release_mime_type = signed_mime_type
          FileUtils.cp_r(signed_tmp.path, release_tmp.path, remove_destination: true)
        else
          local_file = release_tmp.path + '.asc'
          remote_file = filepath + '.gpg'
          yield remote_file if block_given?
          raise "Unable to locate #{filepath} signature file" unless File.exists?(local_file)
          s3_store(local_file, remote_file, signed_mime_type, self.cache_control)
          File.unlink(local_file)
        end
      else
        raise "Signing the #{filepath} file failed."
      end

      if signed_tmp != nil
        signed_tmp.close
        signed_tmp.unlink
      end
    else
      # remove an existing Release.gpg, if it was there
      unless inrelease
        s3_remove(filepath + '.gpg')
      end
    end

    s3_store(release_tmp.path, filepath, release_mime_type, self.cache_control)
    release_tmp.unlink
  end

  def update_manifest(manifest)
    self.components << manifest.component unless self.components.include?(manifest.component)
    self.architectures << manifest.architecture unless self.architectures.include?(manifest.architecture)
    self.files.merge!(manifest.files)
  end

  def validate_others
    to_apply = []
    self.components.each do |comp|
      self.supported_archs.each do |arch|
        next if self.files.has_key?("#{comp}/binary-#{arch}/Packages")

        m = Deb::S3::Manifest.new
        m.codename = self.codename
        m.component = comp
        m.architecture = arch
        m.cache_control = self.cache_control
        m.acquire_by_hash = self.acquire_by_hash
        if block_given?
          m.write_to_s3 { |f| yield f }
        else
          m.write_to_s3
        end
        to_apply << m
      end
    end

    to_apply.each { |m| self.update_manifest(m) }
  end
end
