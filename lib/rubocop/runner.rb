# encoding: utf-8

module RuboCop
  # This class handles the processing of files, which includes dealing with
  # formatters and letting cops inspect the files.
  class Runner
    attr_reader :errors, :aborting
    alias_method :aborting?, :aborting

    def initialize(options, config_store)
      @options = options
      @config_store = config_store
      @errors = []
      @aborting = false
    end

    # Takes a block which it calls once per inspected file.  The block shall
    # return true if the caller wants to break the loop early.
    def run(paths)
      target_files = find_target_files(paths)

      inspected_files = []
      all_passed = true

      formatter_set.started(target_files)

      target_files.each do |file|
        break if aborting?

        offenses = process_file(file)

        all_passed = false if offenses.any? do |o|
          o.severity >= fail_level
        end

        inspected_files << file

        break if @options[:fail_fast] && !all_passed
      end

      formatter_set.finished(inspected_files.freeze)
      formatter_set.close_output_files

      all_passed
    end

    def abort
      @aborting = true
    end

    private

    def find_target_files(paths)
      target_finder = TargetFinder.new(@config_store, @options)
      target_files = target_finder.find(paths)
      target_files.each(&:freeze).freeze
    end

    def process_file(file)
      puts "Scanning #{file}" if @options[:debug]
      processed_source, offenses = process_source(file)

      if offenses.any?
        formatter_set.file_started(file, offenses)
        formatter_set.file_finished(file, offenses.compact.sort.freeze)
        return offenses
      end

      formatter_set.file_started(
        file, cop_disabled_line_ranges: processed_source.disabled_line_ranges)

      # When running with --auto-correct, we need to inspect the file (which
      # includes writing a corrected version of it) until no more corrections
      # are made. This is because automatic corrections can introduce new
      # offenses. In the normal case the loop is only executed once.
      loop do
        # The offenses that couldn't be corrected will be found again so we
        # only keep the corrected ones in order to avoid duplicate reporting.
        offenses.select!(&:corrected?)

        new_offenses, updated_source_file = inspect_file(processed_source)
        offenses += new_offenses.reject { |n| offenses.include?(n) }
        break unless updated_source_file

        # We have to reprocess the source to pickup the changes. Since the
        # change could (theoretically) introduce parsing errors, we break the
        # loop if we find any.
        processed_source, parse_offenses = process_source(file)
        offenses += parse_offenses if parse_offenses.any?
      end

      formatter_set.file_finished(file, offenses.compact.sort.freeze)
      offenses
    end

    def process_source(file)
      begin
        processed_source = SourceParser.parse_file(file)
      rescue Encoding::UndefinedConversionError, ArgumentError => e
        range = Struct.new(:line, :column, :source_line).new(1, 0, '')
        return [
          nil,
          [Cop::Offense.new(:fatal, range, e.message.capitalize + '.',
                            'Parser')]]
      end

      [processed_source, []]
    end

    def inspect_file(processed_source)
      config = @config_store.for(processed_source.file_path)
      team = Cop::Team.new(mobilized_cop_classes(config), config, @options)
      offenses = team.inspect_file(processed_source)
      @errors.concat(team.errors)
      [offenses, team.updated_source_file?]
    end

    def mobilized_cop_classes(config)
      @mobilized_cop_classes ||= {}
      @mobilized_cop_classes[config.object_id] ||= begin
        cop_classes = Cop::Cop.all

        if @options[:only]
          cop_classes.select! do |c|
            @options[:only].include?(c.cop_name) || @options[:lint] && c.lint?
          end
        else
          # filter out Rails cops unless requested
          cop_classes.reject!(&:rails?) unless run_rails_cops?(config)

          # filter out style cops when --lint is passed
          cop_classes.select!(&:lint?) if @options[:lint]
        end

        cop_classes
      end
    end

    def run_rails_cops?(config)
      @options[:rails] || config['AllCops']['RunRailsCops']
    end

    def formatter_set
      @formatter_set ||= begin
        set = Formatter::FormatterSet.new
        pairs = @options[:formatters] || [[Options::DEFAULT_FORMATTER]]
        pairs.each do |formatter_key, output_path|
          set.add_formatter(formatter_key, output_path)
        end
        set
      rescue => error
        warn error.message
        $stderr.puts error.backtrace
        exit(1)
      end
    end

    def fail_level
      @fail_level ||= RuboCop::Cop::Severity.new(
        @options[:fail_level] || :refactor)
    end
  end
end
