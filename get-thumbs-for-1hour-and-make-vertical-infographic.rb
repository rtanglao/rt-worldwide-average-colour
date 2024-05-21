#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
require 'typhoeus'
require 'amazing_print'
require 'time'
require 'date'
require 'logger'
require 'io/console'
require 'parseconfig'
require 'fileutils'
require 'pry'
require 'pry-byebug'
require 'tzinfo'
require 'down/http'
require 'json'
require 'rmagick'

include Magick

def get_flickr_response(url, params, _logger)
  url = "https://api.flickr.com/#{url}"
  try_count = 0
  begin
    result = Typhoeus::Request.get(
      url,
      params: params
    )
    x = JSON.parse(result.body)
  rescue JSON::ParserError
    try_count += 1
    if try_count < 4
      logger.debug "JSON::ParserError exception, retry:#{try_count}"
      sleep(10)
      retry
    else
      logger.debug 'JSON::ParserError exception, retrying FAILED'
      x = nil
    end
  end
  x
end

logger = Logger.new($stderr)
logger.level = Logger::DEBUG

if ARGV.length < 4
  puts "usage: #{$PROGRAM_NAME} yyyy mm dd hh"
  exit
end

YYYY = ARGV[0]
MM = ARGV[1]
DD = ARGV[2]
HH = ARGV[3]
# THUMBS/2024-05-20
THUMBS_PATH = "THUMBS/#{format('%4.4d', YYYY.to_i)}-#{format('%2.2d', MM.to_i)}-#{format('%2.2d', DD.to_i)}"
flickr_config = ParseConfig.new('flickr.conf').params

api_key = flickr_config['api_key']

BEGIN_TIME = Time.parse "#{YYYY} #{MM}/#{DD} #{HH}:00 -0800"
END_TIME = Time.parse "#{YYYY} #{MM}/#{DD} #{HH}:59:59 -0800"
logger.debug "BEGIN_TIME: #{BEGIN_TIME.ai}"
logger.debug "END_TIME: #{END_TIME.ai}"

begin_mysql_time = Time.at(BEGIN_TIME).strftime('%Y-%m-%d %H:%M:%S')
logger.debug "BEGIN mysql TIME: #{begin_mysql_time.ai}"
end_mysql_time = Time.at(END_TIME).strftime('%Y-%m-%d %H:%M:%S')
logger.debug "END mysql TIME: #{end_mysql_time.ai}"

extras_str = 'description, license, date_upload, date_taken, owner_name, icon_server,'\
             'original_format, last_update, geo, tags, machine_tags, o_dims, views,'\
             'media, path_alias, url_sq, url_t, url_s, url_m, url_z, url_l, url_o,'\
             'url_c, url_q, url_n, url_k, url_h, url_b'
flickr_url = 'services/rest/'
logger.debug "begin_mysql_time:#{begin_mysql_time}"

NUM_PHOTOS_TO_DOWNLOAD = 500

page = 1
photos_to_retrieve = NUM_PHOTOS_TO_DOWNLOAD
first_page = true
csv_array = []
photo_index = 0
while photos_to_retrieve.positive?
  url_params =
    {
      method: 'flickr.photos.search',
      media: 'photos', # Just photos no videos
      content_type: 1, # Just photos, no videos, screenshots, etc
      api_key: api_key,
      format: 'json',
      nojsoncallback: '1',
      extras: extras_str,
      sort: 'date-taken-asc',
      per_page: NUM_PHOTOS_TO_DOWNLOAD,
      page: page.to_s,
      # Looks like unix time support is broken so use mysql time
      min_taken_date: begin_mysql_time,
      max_taken_date: end_mysql_time
    }
  photos_on_this_page = get_flickr_response(flickr_url, url_params, logger)
  if first_page
    first_page = false
    photos_per_page = photos_on_this_page['photos']['perpage'].to_i
    photos_to_retrieve = photos_on_this_page['photos']['total'].to_i - photos_per_page
  else
    photos_to_retrieve -= photos_per_page
  end
  page += 1
  logger.debug "STATUS from flickr API:#{photos_on_this_page['stat']} retrieved page:"\
    "#{photos_on_this_page['photos']['page']} of:#{photos_on_this_page['photos']['pages'].to_i}"

  photos_on_this_page['photos']['photo'].each do |photo|
    photo_index += 1
    logger.debug "PHOTO datetaken from flickr API: #{photo['datetaken']}"
    logger.debug "PHOTO dateupload from flickr API: #{photo['dateupload']}"

    skip = false
    begin
      datetaken = Time.parse(photo['datetaken'])
    rescue ArgumentError
      logger.debug "Parser EXCEPTION in datetaken: #{photo['datetaken']}!! SKIPPED"
      skip = true
    end
    if skip
      skip = false
      next
    end
    datetaken = datetaken.utc
    logger.debug "PHOTO datetaken:#{datetaken}"
    photo['datetaken'] = datetaken
    dateupload = Time.at(photo['dateupload'].to_i)
    logger.debug "PHOTO dateupload: #{dateupload}"
    photo['dateupload'] = dateupload
    lastupdate = Time.at(photo['lastupdate'].to_i)
    logger.debug "PHOTO lastupdate:#{lastupdate}"
    photo['lastupdate'] = lastupdate
    photo['id'] = photo['id'].to_i
    id = photo['id']
    logger.debug "PHOTO id: #{id}"
    logger.debug "photo.ai: #{photo.ai}"
    photo['description_content'] = photo['description']['_content']
    photo['thumbs_path'] = THUMBS_PATH
    # filename format:     # 000001-2024-01-01-01-owner-id-title-75x75
    thumb_filename = "#{format('%6.6d', photo_index)}-"\
    "#{format('%4.4d', YYYY.to_i)}-#{format('%2.2d', MM.to_i)}-"\
    "#{format('%2.2d', DD.to_i)}-#{format('%2.2d', HH.to_i)}-"\
    "#{photo['owner'].gsub('@', '_')}"\
    "-#{photo['id']}-#{photo['title'].gsub(/[^\w.]/, '_')[0..31]}-75x75.jpg"
    logger.debug "thumb_filename:#{thumb_filename}"
    photo['thumb_filename'] = thumb_filename
    photo_without_nested_stuff = photo.except('description')
    csv_array.push(photo_without_nested_stuff)
    # logger.debug photo.except("description").ai
    logger.debug "photo_without_nested_stuff #{photo_without_nested_stuff.ai}"
    binding.pry
  end
end
photos.sort! { |a, b| a['dateupload'] <=> b['dateupload'] }
# Get last photo and figure out the date for the Pacific timezone
# and skip prior dates (if there are any)
last = photos[-1]
tz = TZInfo::Timezone.get('America/Vancouver')
localtime = tz.to_local(Time.at(last['dateupload']))
localyyyy = localtime.strftime('%Y').to_i
localmm = localtime.strftime('%m').to_i
localdd = localtime.strftime('%d').to_i
startdate = tz.local_time(localyyyy, localmm, localdd, 0, 0).to_i
photos.reject! { |p| p['dateupload'] < startdate }
exit if photos.length.empty?
BARCODE_SLICE = '/tmp/resized.png'
HEIGHT = 640
WIDTH = 1
# Create barcode/yyyy/mm/dd directory if it doesn't exist
DIRECTORY = format(
  'barcode/%<yyyy>4.4d/%<mm>2.2d/%<dd>2.2d',
  yyyy: localyyyy, mm: localmm, dd: localdd
)
ID_FILEPATH = "#{DIRECTORY}/processed-ids.txt"
BARCODE_FILEPATH = 'barcode/barcode.png'
DAILY_BARCODE_FILEPATH = format(
  '%<dir>s/%<yyyy>4.4d-%<mm>2.2d-%<dd>2.2d.png',
  dir: DIRECTORY, yyyy: localyyyy, mm: localmm, dd: localdd
)
FileUtils.mkdir_p DIRECTORY
processed_ids = []
processed_ids = IO.readlines(ID_FILEPATH).map(&:to_i) if File.exist?(ID_FILEPATH)
check_daily_file_exists = true
photos.each do |photo|
  id = photo['id']
  next if processed_ids.include?(id)

  # Download the thumbnail to /tmp
  logger.debug "DOWNLOADING #{id}"
  # 640 height files shouldn't be more than 1 MB!!!
  retry_count = 0
  begin
    tempfile = Down::Http.download(photo['url_l'], max_size: 1 * 1024 * 1024)
  rescue Down::ClientError, Down::NotFound => e
    retry_count += 1
    retry if retry_count < 3
    next # raise(e) ie. skip the photo if we can't download it
  end
  thumb = Image.read(tempfile.path).first
  resized = thumb.resize(WIDTH, HEIGHT)
  resized.write(BARCODE_SLICE)
  if check_daily_file_exists && !File.exist?(DAILY_BARCODE_FILEPATH)
    FileUtils.cp(BARCODE_SLICE, DAILY_BARCODE_FILEPATH)
    check_daily_file_exists = false
  else
    image_list = Magick::ImageList.new(DAILY_BARCODE_FILEPATH, BARCODE_SLICE)
    montaged_images = image_list.montage { |image| image.tile = '2x1', image.geometry = '+0+0' }
    montaged_images.write(DAILY_BARCODE_FILEPATH)
  end
  File.delete(tempfile.path)
  # After the thumbnail is downloaded,  add the id to the file and to the array
  # so we don't download it again!
  File.open(ID_FILEPATH, 'a') { |f| f.write("#{id}\n") }
  processed_ids.push(id)
  FileUtils.cp(DAILY_BARCODE_FILEPATH, BARCODE_FILEPATH)
end
