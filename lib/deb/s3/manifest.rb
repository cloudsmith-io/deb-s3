# -*- encoding : utf-8 -*-
require "tempfile"
require "zlib"
require 'deb/s3/utils'
require 'deb/s3/package'

class Deb::S3::Manifest
  include Deb::S3::Utils

  attr_accessor :codename
  attr_accessor :component
  attr_accessor :cache_control
  attr_accessor :architecture
  attr_accessor :fail_if_exists
  attr_accessor :skip_package_upload
  attr_accessor :acquire_by_hash

  attr_accessor :files

  attr_reader :packages
  attr_reader :packages_to_be_upload

  def initialize
    @packages = []
    @packages_to_be_upload = []
    @component = nil
    @architecture = nil
    @files = {}
    @cache_control = ""
    @fail_if_exists = false
    @skip_package_upload = false
    @acquire_by_hash = true
  end

  class << self
    def retrieve(
        codename, component, architecture, cache_control, fail_if_exists,
        skip_package_upload=false, acquire_by_hash=true)
      m = if s = Deb::S3::Utils.s3_read(
          "dists/#{codename}/#{component}/binary-#{architecture}/Packages")
        self.parse_packages(s)
      else
        self.new
      end

      m.codename = codename
      m.component = component
      m.architecture = architecture
      m.cache_control = cache_control
      m.fail_if_exists = fail_if_exists
      m.skip_package_upload = skip_package_upload
      m.acquire_by_hash = acquire_by_hash
      m
    end

    def parse_packages(str)
      m = self.new
      str.split("\n\n").each do |s|
        next if s.chomp.empty?
        m.packages << Deb::S3::Package.parse_string(s)
      end
      m
    end
  end

  def add(pkg, preserve_versions, needs_uploading=true)
    if self.fail_if_exists
      packages.each { |p|
        next unless p.name == pkg.name && \
                    p.full_version == pkg.full_version && \
                    File.basename(p.url_filename) != \
                    File.basename(pkg.url_filename)
        raise AlreadyExistsError,
              "package #{pkg.name}_#{pkg.full_version} already exists " \
              "with different filename (#{p.url_filename})"
      }
    end
    if preserve_versions
      packages.delete_if { |p| p.name == pkg.name && p.full_version == pkg.full_version }
    else
      packages.delete_if { |p| p.name == pkg.name }
    end
    packages << pkg
    packages_to_be_upload << pkg if needs_uploading
    pkg
  end

  def delete_package(pkg, versions=nil)
    deleted = []
    new_packages = @packages.select { |p|
        # Include packages we didn't name
        if p.name != pkg
           p
        # Also include the packages not matching a specified version
        elsif (!versions.nil? and p.name == pkg and !versions.include?(p.version) and !versions.include?("#{p.version}-#{p.iteration}") and !versions.include?(p.full_version))
            p
        end
    }
    deleted = @packages - new_packages
    @packages = new_packages
    deleted
  end

  def generate
    @packages.collect { |pkg| pkg.generate }.join("\n")
  end

  def write_to_s3
    manifest = self.generate

    unless self.skip_package_upload
      # store any packages that need to be stored
      @packages_to_be_upload.each do |pkg|
        yield pkg.url_filename if block_given?
        s3_store(pkg.filename, pkg.url_filename, 'application/octet-stream; charset=binary', self.cache_control, self.fail_if_exists)
      end
    end

    comp_path = "#{self.component}/binary-#{self.architecture}"
    code_path = "#{self.codename}/#{comp_path}"
    dist_path = "dists/#{code_path}"

    # generate the Packages file
    filename = 'Packages'
    pkgs_temp = Tempfile.new(filename)
    pkgs_temp.write manifest
    pkgs_temp.close
    f = "#{dist_path}/#{filename}"
    yield f if block_given?

    checksums = hashfile(pkgs_temp.path)
    @files["#{comp_path}/#{filename}"] = checksums

    ct = 'text/plain; charset=UTF-8'
    s3_store(pkgs_temp.path, f, ct, self.cache_control)
    if self.acquire_by_hash
      checksums.each do |type, checksum|
        next if type == :size
        type = type.to_s.upcase
        type = "#{type}Sum" if type == 'MD5'
        f = "#{dist_path}/by-hash/#{type}/#{checksum}"
        s3_store(pkgs_temp.path, f, ct, self.cache_control)
      end
    end
    pkgs_temp.unlink

    # generate the Packages.gz file
    filename = 'Packages.gz'
    gztemp = Tempfile.new(filename)
    gztemp.close
    Zlib::GzipWriter.open(gztemp.path) { |gz| gz.write manifest }
    f = "#{dist_path}/#{filename}"
    yield f if block_given?

    checksums = hashfile(gztemp.path)
    @files["#{comp_path}/#{filename}"] = checksums

    ct = 'application/x-gzip; charset=binary'
    s3_store(gztemp.path, f, ct, self.cache_control)
    if self.acquire_by_hash
      checksums.each do |type, checksum|
        next if type == :size
        type = type.to_s.upcase
        type = "#{type}Sum" if type == 'MD5'
        f = "#{dist_path}/by-hash/#{type}/#{checksum}"
        s3_store(gztemp.path, f, ct, self.cache_control)
      end
    end
    gztemp.unlink

    nil
  end

  def hashfile(path)
    {
      :size   => File.size(path),
      :sha1   => Digest::SHA1.file(path).hexdigest,
      :sha256 => Digest::SHA256.file(path).hexdigest,
      :md5    => Digest::MD5.file(path).hexdigest
    }
  end
end
