#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
require 'amazing_print'
require 'json'
require 'time'
require 'date'
require 'csv'
require 'logger'
require 'rmagick'
require 'pry'
require 'mini_magick'
require 'pry'
require 'pry-byebug'
require 'down/http'
require 'rake'
require 'securerandom'

logger = Logger.new($stderr)
logger.level = Logger::DEBUG

VERTICAL = true
HORIZONTAL = false

def append_image(image_to_be_appended, image, vertical_or_horizontal)
  image_list = Magick::ImageList.new(image_to_be_appended, image)
  appended_images = image_list.append(vertical_or_horizontal)
  appended_images.write(image)
end

if ARGV.empty?
  puts "usage: #{$PROGRAM_NAME} <hourly_metadatafilename>"
  exit
end

metadata_filename = ARGV[0]
relevant_metadata = []
CSV.foreach(metadata_filename, headers: true) do |row|
  id = row['id'].to_i
  url_sq = row['url_sq']
  #   if relevant_metadata.any? { |m| m[:url_sq] == url_sq }
  #    logger.debug "FOUND duplicate of id: #{id} SKIPPING URL: #{url_sq}"
  #    next
  #  end
  relevant_metadata.push({ id: id,
                           url_sq: url_sq,
                           thumb_filename: row['thumb_filename'] })
  logger.debug "last: #{relevant_metadata.last}"
end
length = relevant_metadata.length
logger.debug "length: #{length}"
LARGEST_NUMBER_OF_HOURLY_PHOTOS = 209_999 # Magic number based on the fact that 215,000 photos were uploaded in 1 hour on Christmas Day 2023
MAX_SAMPLE_SIZE = 4000
sample_size = if length > LARGEST_NUMBER_OF_HOURLY_PHOTOS
                MAX_SAMPLE_SIZE
              else
                (length / LARGEST_NUMBER_OF_HOURLY_PHOTOS.to_f * MAX_SAMPLE_SIZE).round
              end
logger.debug "sample_size: #{sample_size}"
sampled_relevant_metadata = relevant_metadata.sample(sample_size)
output_filename = "#{File.basename(metadata_filename)}".ext('png')
output_filename = output_filename.gsub('metadata', 'average-colour')
logger.debug "output_filename: #{output_filename}"
AVERAGE_COLOUR_FILENAME = "average_colour-#{SecureRandom.hex}.png"
logger.debug "average colour filename: #{AVERAGE_COLOUR_FILENAME}"
sampled_relevant_metadata.each.with_index do |m, i|
  logger.debug "DOWNLOADING id: #{m[:id]}, url: #{m[:url_sq]}"
  skip = false
  begin
    tempfile = Down::Http.download(m[:url_sq], max_size: 1 * 64 * 1024) # shouldn't be more than 64K
  rescue Down::ClientError
    skip = true
  end
  next if skip

  image = MiniMagick::Image.open(tempfile.path)
  image.resize '1x1'
  image.format 'png'
  image.write AVERAGE_COLOUR_FILENAME
  if i.zero?
    FileUtils.mv(AVERAGE_COLOUR_FILENAME, output_filename)
  else
    append_image(AVERAGE_COLOUR_FILENAME, output_filename, VERTICAL)
  end
  File.delete(tempfile.path)
  if (i % 100).zero? 
    sleep(2) # sleep 2 seconds every 100 photos
  end
end
