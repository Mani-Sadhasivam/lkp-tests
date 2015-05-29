require "#{LKP_SRC}/lib/common.rb"
require "#{LKP_SRC}/lib/yaml.rb"
require "#{LKP_SRC}/lib/result.rb"
require "#{LKP_SRC}/lib/stats.rb"
require "#{LKP_SRC}/lib/job.rb"

class Completion
	def initialize(line)
		fields = line.split
		@time = Time.parse(fields[0..2].join ' ')
		@_rt = ResultRoot_.new fields[3]
		@status = fields.drop(4).join ' '
	end

	attr_reader :time, :status

	def to_s
		"#{@time} #{@_rt} #{@status}"
	end
end

# Result root for multiple runs of a job
# M here stands for multiple runs
# _rt or mrt may be used as variable name
class MResultRoot
	DMESG_GLOB1 = '[0-9]*/.dmesg*'
	DMESG_GLOB2 = '[0-9]*/dmesg*'
	JOB_GLOB = '[0-9]*/job.yaml'
	COMPLETIONS_FILE = 'completions'
	MATRIX = 'matrix.json'

	def initialize(path)
		@path = path
		@path.freeze
		@axes = calc_axes
	end

	attr_reader :axes

	def to_s
		@path
	end

	def calc_axes
		if job_file
			job.axes
		else
			rp = ResultPath.parse @path
			Hash[rp.to_a]
		end
	end

	def axes_path
		as = deepcopy(@axes)
		if job_file
			path_params = job.path_params
		else
			rp = ResultPath.parse @path
			path_params = rp['path_params']
		end
		as['path_params'] = path_params
		as
	end

	def goto_commit(commit)
		rp = ResultPath.new
		rp.update(axes_path)
		rp['commit'] = commit
		_rtp = rp._result_root
		MResultRoot.new _rtp if File.exists? _rtp
	end

	def path(sub)
		File.join @path, sub
	end

	def dmesgs
		dmesgs = Dir[path(DMESG_GLOB1)]
		dmesgs = Dir[path(DMESG_GLOB2)] if dmesgs.size == 0
		dmesgs
	end

	def job_file
		jobs = Dir[path(JOB_GLOB)]
		jobs[0] if jobs.size != 0
	end

	def job
		Job.open job_file
	end

	def collection
		MResultRootCollection.new axes_path
	end

	def boot_collection
		bc = collection.unselect('path_params', 'rootfs')
		bc.testcase = 'boot'
		bc
	end

	def matrix_file
		path(MATRIX)
	end

	def matrix
		try_load_json matrix_file
	end

	def complete_matrix(m = nil)
		m ||= matrix
		if m['last_state.is_incomplete_run']
			m = deepcopy(m)
			filter_incomplete_run m
			m
		else
			m
		end
	end

	def runs(m = nil)
		m ||= matrix
		return 0, 0 unless m
		all_runs = matrix_cols m
		cm = complete_matrix m
		complete_runs = matrix_cols cm
		[all_runs, complete_runs]
	end

	def completions
		File.open(path(COMPLETIONS_FILE), "r") { |f|
			f.each_line.map { |line|
				Completion.new line
			}.sort_by { |cmp| -cmp.time.to_i }
		}
	rescue Errno::ENOENT
		[]
	end

	ResultPath::MAXIS_KEYS.each { |k|
		define_method(k.intern) { @axes[k] }
	}
end

class << MResultRoot
	def valid?(path)
		return false if !File.exists? path
		return Dir[File.join path, self::JOB_GLOB].first
	end
end

class MResultRootCollection
	def initialize(conditions)
		cond = deepcopy(conditions)
		ResultPath::MAXIS_KEYS.each { |f|
			instance_variable_set(instance_variable_sym(f), conditions.fetch(f, '.*'))
			cond.delete f
		}
		@other_conditions = cond.values.join ' '
	end

	include Enumerable

	ResultPath::MAXIS_KEYS.each { |k|
		attr_accessor k
	}

	def pattern
		result_path = ResultPath.new
		ResultPath::MAXIS_KEYS.each { |k| result_path[k] = instance_variable_get(instance_variable_sym(k)) }
		result_path._result_root
	end

	def each
		block_given? or return enum_for(__method__)

		`lkp _rt '#{pattern}' #{@other_conditions}`.each_line { |_rtp|
			_rtp = _rtp.strip
			if MResultRoot.valid? _rtp
				yield MResultRoot.new _rtp.strip
			end
		}
	end

	def unselect(*fields)
		fields.each { |f|
			instance_variable_set(instance_variable_sym(f), '.*')
		}
		self
	end

	def set_testbox(value)
		self.testbox = value
		self
	end

	def set_testcase(value)
		self.testcase = value
		self
	end

	def set_path_params(value)
		self.path_params = value
		self
	end

	def set_rootfs(value)
		self.rootfs = value
		self
	end

	def set_kconfig(value)
		self.kconfig = value
		self
	end

	def set_commit(value)
		self.commit = value
		self
	end
end
