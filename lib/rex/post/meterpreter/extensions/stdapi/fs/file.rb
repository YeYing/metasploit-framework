#!/usr/bin/env ruby

require 'rex/post/file'
require 'rex/post/meterpreter/channel'
require 'rex/post/meterpreter/channels/pools/file'
require 'rex/post/meterpreter/extensions/stdapi/stdapi'
require 'rex/post/meterpreter/extensions/stdapi/fs/io'
require 'rex/post/meterpreter/extensions/stdapi/fs/file_stat'
require 'fileutils'

module Rex
module Post
module Meterpreter
module Extensions
module Stdapi
module Fs

###
#
# This class implements the Rex::Post::File interface and wraps interaction
# with files on the remote machine.
#
###
class File < Rex::Post::Meterpreter::Extensions::Stdapi::Fs::IO

	include Rex::Post::File

	class << self
		attr_accessor :client
	end

	#
	# Return the directory separator, i.e.: "/" on unix, "\\" on windows
	#
	def File.separator()
		# The separator won't change, so cache it to prevent sending
		# unnecessary requests.
		return @separator if @separator

		request = Packet.create_request('stdapi_fs_separator')

		# Fall back to the old behavior of always assuming windows.  This
		# allows meterpreter executables built before the addition of this
		# command to continue functioning.
		begin
			response = client.send_request(request)
			@separator = response.get_tlv_value(TLV_TYPE_STRING)
		rescue RequestError
			@separator = "\\"
		end

		return @separator
	end

	class << self
		alias :Separator :separator
		alias :SEPARATOR :separator
	end

	#
	# Search for files.
	#
	def File.search( root=nil, glob="*.*", recurse=true, timeout=-1 )

		files = ::Array.new

		request = Packet.create_request( 'stdapi_fs_search' )

		root = client.unicode_filter_decode(root) if root
		root = root.chomp( '\\' ) if root

		request.add_tlv( TLV_TYPE_SEARCH_ROOT, root )
		request.add_tlv( TLV_TYPE_SEARCH_GLOB, glob )
		request.add_tlv( TLV_TYPE_SEARCH_RECURSE, recurse )

		# we set the response timeout to -1 to wait indefinatly as a
		# search could take an indeterminate ammount of time to complete.
		response = client.send_request( request, timeout )
		if( response.result == 0 )
			response.each( TLV_TYPE_SEARCH_RESULTS ) do | results |
				files << {
					'path' => client.unicode_filter_encode( results.get_tlv_value( TLV_TYPE_FILE_PATH ).chomp( '\\' ) ),
					'name' => client.unicode_filter_encode( results.get_tlv_value( TLV_TYPE_FILE_NAME ) ),
					'size' => results.get_tlv_value( TLV_TYPE_FILE_SIZE )
				}
			end
		end

		return files
	end

	#
	# Returns the base name of the supplied file path to the caller.
	#
	def File.basename(*a)
		path = a[0]

		# Allow both kinds of dir serparators since lots and lots of code
		# assumes one or the other so this ends up getting called with strings
		# like: "C:\\foo/bar"
		path =~ %r#.*[/\\](.*)$#

		Rex::FileUtils.clean_path($1 || path)
	end

	#
	# Expands a file path, substituting all environment variables, such as
	# %TEMP%.
	#
	def File.expand_path(path)
		request = Packet.create_request('stdapi_fs_file_expand_path')

		request.add_tlv(TLV_TYPE_FILE_PATH, client.unicode_filter_decode( path ))

		response = client.send_request(request)

		return client.unicode_filter_encode( response.get_tlv_value(TLV_TYPE_FILE_PATH) )
	end


	#
	# Calculates the MD5 (16-bytes raw) of a remote file
	#
	def File.md5(path)
		request = Packet.create_request('stdapi_fs_md5')

		request.add_tlv(TLV_TYPE_FILE_PATH, client.unicode_filter_decode( path ))

		response = client.send_request(request)

		# This is not really a file name, but a raw hash in bytes
		return response.get_tlv_value(TLV_TYPE_FILE_NAME)
	end

	#
	# Calculates the SHA1 (20-bytes raw) of a remote file
	#
	def File.sha1(path)
		request = Packet.create_request('stdapi_fs_sha1')

		request.add_tlv(TLV_TYPE_FILE_PATH, client.unicode_filter_decode( path ))

		response = client.send_request(request)

		# This is not really a file name, but a raw hash in bytes
		return response.get_tlv_value(TLV_TYPE_FILE_NAME)
	end

	#
	# Performs a stat on a file and returns a FileStat instance.
	#
	def File.stat(name)
		return client.fs.filestat.new( name )
	end

	#
	# Determines if a file exists and returns true/false
	#
	def File.exists?(name)
		r = client.fs.filestat.new(name) rescue nil
		r ? true : false
	end

	#
	# Performs a delete on the specified file.
	#
	def File.rm(name)
		request = Packet.create_request('stdapi_fs_delete_file')

		request.add_tlv(TLV_TYPE_FILE_PATH, client.unicode_filter_decode( name ))

		response = client.send_request(request)

		return response
	end

	#
	# Performs a delete on the specified file.
	#
	def File.unlink(name)
		return File.rm(name)
	end

	#
	# Upload one or more files to the remote computer the remote
	# directory supplied in destination.
	#
	def File.upload(destination, *src_files, &stat)
		src_files.each { |src|
			dest = destination

			stat.call('uploading', src, dest) if (stat)
			if (self.basename(destination) != ::File.basename(src))
				dest += self.separator + ::File.basename(src)
			end

			upload_file(dest, src)
			stat.call('uploaded', src, dest) if (stat)
		}
	end

	#
	# Upload a single file.
	#
	def File.upload_file(dest_file, src_file)
		# Open the file on the remote side for writing and read
		# all of the contents of the local file
		dest_fd = client.fs.file.new(dest_file, "wb")
		src_buf = ''

		::File.open(src_file, 'rb') { |f|
			src_buf = f.read(f.stat.size)
		}

		begin
			dest_fd.write(src_buf)
		ensure
			dest_fd.close
		end
	end

	#
	# Download one or more files from the remote computer to the local
	# directory supplied in destination.
	#
	def File.download(dest, *src_files, &stat)
		src_files.each { |src|
			if (::File.basename(dest) != File.basename(src))
				# The destination when downloading is a local file so use this
				# system's separator
				dest += ::File::SEPARATOR + File.basename(src)
			end

			stat.call('downloading', src, dest) if (stat)

			download_file(dest, src)

			stat.call('downloaded', src, dest) if (stat)
		}
	end

	#
	# Download a single file.
	#
	def File.download_file(dest_file, src_file)
		src_fd = client.fs.file.new(src_file, "rb")
		dir = ::File.dirname(dest_file)
		::FileUtils.mkdir_p(dir) if dir and not ::File.directory?(dir)

		dst_fd = ::File.new(dest_file, "wb")

		# Keep transferring until EOF is reached...
		begin
			while ((data = src_fd.read) != nil)
				dst_fd.write(data)
			end
		rescue EOFError
		ensure
			src_fd.close
			dst_fd.close
		end
	end

	##
	#
	# Constructor
	#
	##

	#
	# Initializes and opens the specified file with the specified permissions.
	#
	def initialize(name, mode = "r", perms = 0)
		self.client = self.class.client
		self.filed  = _open(name, mode, perms)
	end

	##
	#
	# IO implementators
	#
	##

	#
	# Returns whether or not the file has reach EOF.
	#
	def eof
		return self.filed.eof
	end

	#
	# Returns the current position of the file pointer.
	#
	def pos
		return self.filed.tell
	end

	#
	# Synonym for sysseek.
	#
	def seek(offset, whence = ::IO::SEEK_SET)
		return self.sysseek(offset, whence)
	end

	#
	# Seeks to the supplied offset based on the supplied relativity.
	#
	def sysseek(offset, whence = ::IO::SEEK_SET)
		return self.filed.seek(offset, whence)
	end

protected

	##
	#
	# Internal methods
	#
	##

	#
	# Creates a File channel using the supplied information.
	#
	def _open(name, mode = "r", perms = 0)
		return Rex::Post::Meterpreter::Channels::Pools::File.open(
				self.client, name, mode, perms)
	end

	attr_accessor :client # :nodoc:

end

end; end; end; end; end; end

