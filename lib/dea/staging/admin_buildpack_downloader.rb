require "dea/promise"
require "dea/utils/download"
require "dea/utils/non_blocking_unzipper"
require "em-synchrony/thread"
require "enumerator"

class AdminBuildpackDownloader
  attr_reader :logger

  DOWNLOAD_MUTEX = EventMachine::Synchrony::Thread::Mutex.new
  PARALLEL_DOWNLOADS = 3

  def initialize(buildpacks, destination_directory, custom_logger=nil)
    @buildpacks = buildpacks
    @destination_directory = destination_directory
    @logger = custom_logger || self.class.logger
  end

  def download
    logger.debug("admin-buildpacks.download", buildpacks: @buildpacks)
    return unless @buildpacks

    DOWNLOAD_MUTEX.synchronize do
      download_promises = []
      @buildpacks.each do |buildpack|
        dest_dir = File.join(@destination_directory, buildpack.fetch(:key))
        unless File.exists?(dest_dir)
          download_promises << download_one_buildpack(buildpack, dest_dir)
        end
      end

      failure = nil
      download_promises.each_slice(PARALLEL_DOWNLOADS) do |slice|
        begin
          Dea::Promise.run_in_parallel_and_join(*slice)
        rescue => error
          failure = error if failure.nil?
        end
      end

      raise failure unless failure.nil?
    end
  end

  private

  def download_one_buildpack(buildpack, dest_dir)
    Dea::Promise.new do |p|
      tmpfile = Tempfile.new('temp_admin_buildpack')

      Download.new(buildpack.fetch(:url), tmpfile, nil, logger).download! do |err|
        if err
          p.fail err
        else
          NonBlockingUnzipper.new.unzip_to_folder(tmpfile.path, dest_dir) do |output, status|
            tmpfile.unlink
            if status == 0
              p.deliver
            else
              p.fail output
            end
          end
        end
      end
    end
  end
end
