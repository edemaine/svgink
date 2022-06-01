`#!/usr/bin/env node
`
#log = require 'why-is-node-running'
metadata = require './package.json'
child_process = require 'child_process'
fs = require 'fs/promises'
fsNormal = require 'fs'
path = require 'path'

defaultSettings =
  ## Whether to force conversion, even if SVG file is older than target.
  force: false
  ## Directories to output all or some files.
  outputDir: null  ## default: same directory as input
  outputDirExt:    ## by extension; default is to use outputDir
    '.pdf': null
    '.png': null
  ## Path to inkscape.  Default searches PATH.
  inkscape: 'inkscape'
  ## Maximum number of Inkscapes to run in parallel.
  ## Default = number of physical CPU cores (assuming hyperthreading).
  jobs:
    try
      Math.max 1, require('os').cpus().length // 2
    catch
      1
  ## If an Inkscape process sits idle for this many milliseconds, close it.
  ## Default = 1 minute.  Set to null to disable.
  idle: 60000
  ## If an Inkscape fails to start shell for this many milliseconds, fail.
  ## Default = 5 seconds.  Set to null to disable.
  startTimeout: 5000
  ## If an Inkscape fails to close for this many milliseconds, kill it.
  ## Default = 1 second.  Set to null to disable.
  quitTimeout: 1000
  ## Wait for an input file to stop changing for this many milliseconds
  ## before watch triggers conversion.  Default = 1 second.
  settle: 1000
  ## Whether to sanitize PDF output by blanking out /CreationDate.
  sanitize: true
  ## Buffer size for sanitization.
  bufferSize: 16*1024

invalidFilename = (filename) =>
  /^\s|\s$|;/.test filename

class InkscapeError extends Error
  constructor: (message) ->
    super message
    @name = 'InkscapeError'

class Inkscape
  constructor: (@settings = defaultSettings) ->
  open: (initialUnref) ->
    ## Start Inkscape process.  Returns a Promise.
    ## `initialUnref` specifies whether to unref the Inkscape process
    ## before it finishes starting; set true for secondary Inkscape processes.
    new Promise (@resolve, @reject) =>
      @stdout = @stderr = ''
      @dead = @ready = @started = false
      #console.log (new Date), 'start'
      @process = child_process.spawn @settings.inkscape, ['--shell']
      ## Node can close independent of pipes; rely on @process.ref/unref
      for handle in [@process.stdin, @process.stdout, @process.stderr]
        handle.unref()
      ## Don't wait for a new Inkscape to start, unless requested.
      @process.unref() if initialUnref
      ## Check for failure to start.
      @timeout = setTimeout =>
        @reject new InkscapeError "'#{@settings.inkscape} --shell' produced no '> ' prompt after #{@settings.startTimeout / 1000} seconds"
      , @settings.startTimeout if @settings.startTimeout
      @timeout.unref()
      @process.stderr.on 'data', (buf) =>
        @stderr += buf
      @process.stdout.on 'data', (buf) =>
        @stdout += buf
        if @stdout == '> ' or @stdout.endsWith '\n> '
          #console.log (new Date), 'ready' unless @started
          ## Inkscape just started up, or finished a job.  Allow Node to exit.
          ## In the first case, don't call unref() a second time.
          @process.unref() if @job? or not initialUnref
          @ready = @started = true
          clearTimeout @timeout if @timeout?
          if @settings.idle?
            @timeout = setTimeout (=> @close()), @settings.idle
            @timeout.unref()
          stdout = @stdout
          .replace /> $/, ''  # next prompt
          .replace /^([^\n]*)(\n|$)/, (match, firstLine) =>
            ## Remove first line of output if it includes the job input,
            ## possibly with some complex readline output after first \r.
            if @cmd?.startsWith firstLine.replace /\r[^]*$/, ''
              ''
            else
              match
          stderr = @stderr
          @stdout = @stderr = ''
          @resolve? {...@job, stdout, stderr}
          @resolve = @reject = @job = @cmd = null
      @process.on 'error', (error) =>
        @closed()
        if @reject?
          error[key] = value for key, value of @job if @job?
          @reject error
        else
          throw new InkscapeError "Uncaught Inkscape error: #{error.message}"
      @process.on 'exit', (status, signal) =>
        return if @dead  # ignore exit event after error event
        @closed()
        if status or signal or not @started
          message =
            "'#{@settings.inkscape} --shell' exited " +
            if status
              "with status #{status}"
            else if signal
              "with signal #{signal}"
            else
              "without status or signal before '> ' prompt"
          if @reject?
            error = new InkscapeError message
            error[key] = value for key, value of @job if @job?
            error.status = status
            error.signal = signal
            @reject error
            @resolve = @reject = @job = @cmd = null
          else
            throw new InkscapeError "Uncaught Inkscape crash: #{message}"
        else
          @resolve?(
            stdout: @stdout
            stderr: @stderr
          )
          @resolve = @reject = null
  close: ->
    ## Gently close Inkscape process, or if it doesn't respond, kill it.
    ## Returns a Promise.
    new Promise (@resolve, @reject) =>
      #@process.stdin.write 'quit\n'
      @process.stdin.end()
      @process.unref()
      if @settings.quitTimeout?
        @timeout = setTimeout =>
          @process.kill() unless @dead
        , @settings.quitTimeout
        @timeout.unref()
  closed: ->
    ## Inkscape process has closed; turn everything off.
    @dead = true
    @ready = false
    clearTimeout @timeout if @timeout?
  run: (job) ->
    ## Send job to Inkscape.  Returns a Promise.
    ## Job can be a string to send to the shell,
    ## or an object with a `job` string property,
    ## or an object with `input` and `output` properties for conversion.
    unless @ready and not @job
      throw new InkscapeError 'Attempt to run Inkscape job before ready'
    @ready = false
    @process.ref()
    clearTimeout @timeout if @timeout?
    job = {job} if typeof job == 'string'
    @job = job
    if job?.job?
      @cmd = job.job.replace /\n+$/, ''
    else if job?.input? and job.output?
      @cmd = [
        "file-open:#{@job.input}"
        "export-filename:#{job.output}"
        'export-overwrite'
        'export-do'
      ].join ';'
    else
      throw new InkscapeError "Invalid Inkscape job: #{@job}"
    @cmd += '\n'
    new Promise (@resolve, @reject) =>
      @process.stdin.write @cmd

class SVGProcessor
  constructor: (@settings = defaultSettings) ->
    @inkscapes = []
    @queue = []
    @spawning = false
    @jobs = 0
  convertTo: (input, format) ->
    ## Convert input filename to output file format (e.g. 'pdf' or 'png').
    ## This generates an output filename using `settings.outputDir*`
    ## and then calls `convert`.  The returned promise has an additional
    ## `output` property with the generated filename.
    format = ".#{format}" unless format.startsWith '.'
    parsed = path.parse input
    delete parsed.base  # use ext instead
    if parsed.ext != format
      parsed.ext = format
    else
      parsed.ext += format
    if @settings.outputDirExt[format]?
      dir = @settings.outputDirExt[format]
    else if @settings.outputDir?
      dir = @settings.outputDir
    if dir?
      ## Try to make output directory, synchronously to avoid multiple
      ## async threads trying to make the same directory at once.
      try
        fsNormal.mkdirSync dir, recursive: true
      catch error
        console.log "! Failed to make directory '#{dir}': #{error.message}"
      parsed.dir = dir
    output = path.format parsed
    promise = @convert input, output
    promise.output = output
    promise
  convert: (input, output) ->
    ## Convert input filename to output filename, and then sanitize,
    ## unless output is newer than input or forced.  Returns a Promise.
    @jobs++
    new Promise (resolve, reject) =>
      for filename in [input, output]
        if invalidFilename filename
          @jobs--
          reject new InkscapeError "Inkscape shell does not support filenames with semicolons or leading/trailing spaces: #{filename}"
          @update() if @waiting  # resolve wait() in case last job is skipped
          return
      ## Compare input and output modification times, unless forced.
      unless @settings.force
        try
          outputStat = await fs.stat output
          inputStat = await fs.stat input
      unless inputStat? and outputStat? and inputStat.mtime < outputStat.mtime
        @queue.push {job: {input, output}, resolve, reject}
        @update()
      else
        @jobs--
        resolve {input, output, skip: true}
        @update() if @waiting  # resolve wait() in case last job is skipped
      undefined
  run: (job) ->
    ## Queue job for Inkscape to run.  Returns a Promise.
    ## Job can be a string to send to the shell,
    ## or an object with a `job` string property,
    ## or an object with `input` and `output` properties for conversion.
    @jobs++
    job = {job} if typeof job == 'string'
    new Promise (resolve, reject) =>
      @queue.push {job, resolve, reject}
  wait: ->
    ## Returns a Promise that resolves once all pending jobs are complete.
    ## Only one wait() can be active at a time.
    new Promise (@waiting) => @update()
  close: ->
    ## Close all Inkscape processes once all pending jobs are complete.
    ## Returns a Promise.
    @closing = true
    @wait()
  update: ->
    ## Potentially push jobs from queue or closing to Inkscape processes.
    return unless @queue.length or @waiting or @closing
    ## Filter out any Inkscape processes that died, e.g. from idle timeout.
    @inkscapes = (inkscape for inkscape in @inkscapes when not inkscape.dead)
    ## Check for completed waiting.
    if @waiting and @jobs <= 0
      ## Schedule close() promise to resolve after job promise resolves.
      setTimeout =>
        @waiting()
        @waiting = null
      , 0
      return
    ## Give jobs to any ready Inkscape processes.
    for inkscape in @inkscapes
      if inkscape.ready
        if @queue.length
          @runNow inkscape, @queue.shift()
          return unless @queue.length or @closing
        else if @closing
          inkscape.close()
    ## If we still have jobs, start another Inkscape process to run them.
    ## On Windows, spawning is slow and spawning multiple Inkscapes at once
    ## slows down all spawns (including the first), so only spawn one at a time.
    ## On Linux, spawning is fast, so this isn't a big penalty.
    ## This also avoids spawning many Inkscapes if everything can be finished
    ## quickly with the first spawned Inkscape.
    if not @spawning and @queue.length and @inkscapes.length < @settings.jobs
      @spawning = true
      @inkscapes.push inkscape = new Inkscape @settings
      inkscape.open @inkscapes.length > 1
      .then =>
        @spawning = false
        @update()
      .catch (error) =>
        throw new InkscapeError "Failed to spawn Inkscape: #{error.message}" +
          if error.code == 'ENOENT'
            ' (check PATH environment variable?)'
          else ''
    undefined
  runNow: (inkscape, {job, resolve, reject}) ->
    inkscape.run job
    .then (data) =>
      @update()
      await @sanitize job.output if job.output?
      data
    .then (data) =>
      resolve data
      @jobs--
      @update()
    .catch (error) =>
      error[key] = value for key, value of job
      reject error
  sanitize: (output) ->
    ## Sanitize generated file.  Returns a Promise.
    return unless @settings.sanitize
    switch
      when output.endsWith '.pdf'
        ## Blank out /CreationDate in PDF for easier version control.
        ## Replace these commands with spaces to avoid in-file pointer errors.
        buffer = Buffer.alloc @settings.bufferSize
        fileSize = (await fs.stat output).size
        position = Math.max 0, fileSize - @settings.bufferSize
        file = await fs.open output, 'r+'
        readSize = await file.read buffer, 0, @settings.bufferSize, position
        string = buffer.toString 'binary'  ## must use single-byte encoding!
        match = /\/CreationDate\s*\((?:[^()\\]|\\[^])*\)/.exec string
        if match?
          await file.write ' '.repeat(match[0].length), position + match.index
        await file.close()
  watch: (inputs, formats) ->
    inputs = [inputs] if typeof inputs == 'string'
    formats = [formats] if typeof formats == 'string'
    resolve = null
    queue = []
    watchers = {}
    timeouts = {}
    status = {}
    watch = (input) =>
      watchers[input] = fsNormal.watch input,
        (eventType) => handle input, eventType
    handle = (input) =>
      clearTimeout timeouts[input] if timeouts[input]?
      if status[input] == 'converting'
        status[input] = 'changed'
      else if not status[input]
        ## Restart watcher in case inode changed.
        watchers[input].close()
        watch input
        ## Wait for file to settle.
        timeouts[input] = setTimeout =>
          ## If timeout actually resolves, file has settled.
          status[input] = 'converting'
          for format in formats
            @convertTo input, format
            .then (data) =>
              ## If file changed during conversion, schedule another conversion.
              current = status[input]
              delete status[input]
              if current == 'changed'
                handle input
              ## Output conversion result
              queue.push data
              resolve?()
              resolve = null
        , @settings.settle
    for input in inputs
      continue if watchers[input]?
      watch input
    ## Yield queue items as they become available.
    loop
      await new Promise (r) => resolve = r
      resolve = null
      while queue.length
        yield queue.shift()

help = ->
  console.log """
svgink #{metadata.version}
Usage: #{process.argv[1]} (...options and filenames...)
Documentation: https://github.com/edemaine/svgink

Filenames should specify SVG files.
Optional arguments:
  -h / --help           Show this help message and exit.
  -w / --watch          Continuously watch for changed files and convert them
  -f / --force          Force conversion even if output newer than SVG input
  -o DIR / --output DIR Write all output files to directory DIR
  --op DIR / --output-pdf DIR   Write all .pdf files to directory DIR
  --oP DIR / --output-png DIR   Write all .png files to directory DIR
  -p / --pdf            Convert output SVG files to PDF via Inkscape
  -P / --png            Convert output SVG files to PNG via Inkscape
  --no-sanitize         Don't sanitize PDF output by blanking out /CreationDate
  -j N / --jobs N       Run up to N Inkscape jobs in parallel
"""

main = (args = process.argv[2..]) ->
  start = new Date
  settings = {...defaultSettings}
  processor = new SVGProcessor settings
  watch = false
  formats = []
  inputs = []
  files =
    input: 0
    output: 0
    skip: 0
  skip = 0
  for arg, i in args
    if skip
      skip--
      continue
    switch arg
      when '-h', '--help'
        help()
      when '-w', '--watch'
        watch = true
      when '-f', '--force'
        settings.force = true
      when '-i', '--inkscape'
        skip = 1
        settings.inkscape = args[i+1]
      when '-o', '--output'
        skip = 1
        settings.outputDir = args[i+1]
      when '--op', '--output-pdf'
        skip = 1
        settings.outputDirExt['.pdf'] = args[i+1]
      when '--oP', '--output-png'
        skip = 1
        settings.outputDirExt['.png'] = args[i+1]
      when '-p', '--pdf'
        formats.push 'pdf'
      when '-P', '--png'
        formats.push 'png'
      when '--no-sanitize'
        settings.sanitize = false
      when '-j', '--jobs'
        skip = 1
        arg = parseInt args[i+1]
        if arg
          settings.jobs = arg
        else
          console.warn "Invalid argument to --jobs: #{args[i+1]}"
      else
        files.input++
        inputs.push input = arg
        for format in formats
          files.output++
          processor.convertTo input, format
          .then (data) ->
            if data.skip
              files.skip++
              console.log "- #{data.input} -> #{data.output} (skipped)"
            else
              console.log "* #{data.input} -> #{data.output}"
              console.log data.stdout if data.stdout
              console.log data.stderr if data.stderr
          .catch (error) ->
            console.log "! #{error.input} -> #{error.output} FAILED"
            console.log error
  if watch
    await processor.wait()
  else
    await processor.close()
  if not formats.length
    console.log '! Not enough formats'
    help()
  else if not files
    console.log '! Not enough filename arguments'
    help()
  else
    console.log "> Converted #{files.input} SVG files into #{files.output} files (#{files.output - files.skip} updated) in #{Math.round((new Date) - start) / 1000} seconds"
    console.log "> Skipped #{files.skip} conversions.  To force conversion, use --force" if files.skip
    if watch
      console.log '> Watching for changes... (Ctrl-C to exit)'
      for await data from processor.watch inputs, formats
        console.log "* #{data.input} -> #{data.output}"
        console.log data.stdout if data.stdout
        console.log data.stderr if data.stderr

module.exports = {
  defaultSettings
  InkscapeError
  Inkscape
  SVGProcessor
  main
}

main() if module? and require?.main == module

#setTimeout(log, 5000).unref()
