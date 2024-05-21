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
require 'json'
require 'csv'

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
METADATA_PATH = 'METADATA'
FileUtils.mkdir_p METADATA_PATH
# METADATA/2024-01-01-00-flickr-metadata.csv
METADATA_FILENAME = "#{METADATA_PATH}/#{format('%4.4d', YYYY.to_i)}-#{format('%2.2d', MM.to_i)}-"\
"#{format('%2.2d', MM.to_i)}-flickr-metadata.csv"
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
  end
end
headers = csv_array[0].keys
CSV.open(METADATA_FILENAME, 'w', write_headers: true, headers: headers) do |csv_object|
  csv_array.each { |row_array| csv_object << row_array }
end
