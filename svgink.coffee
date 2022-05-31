`#!/usr/bin/env node
`
#log = require 'why-is-node-running'
metadata = require './package.json'
child_process = require 'child_process'
fs = require 'fs/promises'

defaultSettings =
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
  ## Default = null which means infinity.
  idle: null
  ## If an Inkscape fails to close for this many milliseconds, kill it.
  ## Default = 1 second.  Set to null to disable.
  quitTimeout: 1000
  ## Sanitize PDF output by blanking out /CreationDate.
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
  constructor: (@settings = defaultSettings, @initialUnref) ->
    ## `initialUnref` specifies whether to unref the Inkscape process
    ## before it even initializes; use for secondary Inkscape processes.
  open: ->
    ## Returns a Promise.
    new Promise (@resolve, @reject) =>
      @stdout = @stderr = ''
      @dead = @ready = false
      #console.log (new Date), 'start'
      @process = child_process.spawn @settings.inkscape, ['--shell']
      ## Node can close independent of pipes; rely on @process.ref/unref
      for handle in [@process.stdin, @process.stdout, @process.stderr]
        handle.unref()
      ## Don't wait for a new Inkscape to start, unless requested.
      @process.unref() if @initialUnref
      @process.stderr.on 'data', (buf) =>
        @stderr += buf
      @process.stdout.on 'data', (buf) =>
        @stdout += buf
        if @stdout == '> ' or @stdout.endsWith '\n> '
          #console.log (new Date), 'ready' unless @job?
          ## Inkscape just started up, or finished a job.  Allow Node to exit.
          ## In the first case, don't call unref() a second time.
          @process.unref() if @job? or not @initialUnref
          @ready = true
          if @settings.idle?
            @timeout = setTimeout (=> @close()), @settings.idle
            @timeout.unref()
          stdout = @stdout
          .replace /> $/, ''  # next prompt
          .replace /^([^\n]*)(\n|$)/, (match, firstLine) =>
            ## Remove first line of output if it includes the job input,
            ## possibly with some complex readline output after first \r.
            if @job?.startsWith firstLine.replace /\r[^]*$/, ''
              ''
            else
              match
          stderr = @stderr
          @stdout = @stderr = ''
          @resolve? {stdout, stderr}
          @resolve = @reject = @job = null
      @process.on 'error', (error) =>
        @closed()
        if @reject?
          @reject error
        else
          throw new InkscapeError "Uncaught Inkscape error: #{error.message}"
      @process.on 'exit', (status, signal) =>
        return if @dead  # ignore exit event after error event
        @closed()
        if status or signal
          if @reject?
            @reject {status, signal}
            @resolve = @reject = null
          else
            throw new InkscapeError "Uncaught Inkscape crash: #{status}, #{signal}"
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
    ## Job can be a string to send to the shell, or an object with
    ## `input` and `output` properties, for conversion.
    unless @ready
      throw new InkscapeError 'Attempt to run Inkscape job before ready'
    @ready = false
    @process.ref()
    clearTimeout @timeout if @timeout?
    if typeof job == 'string'
      @job = job.replace /\n+$/, ''
    else if job?.input? and job.output?
      @job = [
        "file-open:#{job.input}"
        "export-filename:#{job.output}"
        'export-overwrite'
        'export-do'
      ].join ';'
    else
      throw new InkscapeError "Invalid Inkscape job: #{job}"
    @job += '\n'
    new Promise (@resolve, @reject) =>
      @process.stdin.write @job

class SVGProcessor
  constructor: (@settings = defaultSettings) ->
    @inkscapes = []
    @queue = []
    @spawning = false
  convert: (input, output) ->
    ## Convert input filename to output filename.  Returns a Promise.
    new Promise (resolve, reject) =>
      for filename in [input, output]
        if invalidFilename filename
          return reject new InkscapeError "Inkscape shell does not support filenames with semicolons or leading/trailing spaces: #{filename}"
      @queue.push {input, output, resolve, reject}
      @update()
  close: ->
    ## Close all Inkscape processes once all pending jobs are complete.
    ## Returns a promise.
    new Promise (@closing) =>
      @update()
  update: ->
    ## Potentially push jobs from queue or closing to Inkscape processes.
    return unless @queue.length or @closing
    ## Filter out any Inkscape processes that died, e.g. from idle timeout.
    @inkscapes = (inkscape for inkscape in @inkscapes when not inkscape.dead)
    ## Check for completed closing.
    if @closing and not @queue.length and
       @inkscapes.every (inkscape) -> not inkscape.job?
      ## Schedule close() promise to resolve after job promise resolves.
      setTimeout (=> @closing()), 0
      return
    ## Give jobs to any ready Inkscape processes.
    for inkscape in @inkscapes
      if inkscape.ready
        if @queue.length
          @run inkscape, @queue.shift()
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
      @inkscapes.push inkscape = new Inkscape @settings, @inkscapes.length
      inkscape.open()
      .then =>
        @spawning = false
        @update()
      .catch (error) =>
        throw new InkscapeError "Failed to spawn Inkscape: #{error.message}"
    undefined
  run: (inkscape, job) ->
    inkscape.run job
    .then (data) =>
      @update()
      @sanitize job.output if job.output?
      data
    .then (data) =>
      job.resolve data
    .catch (error) =>
      job.reject error
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

help = ->
  console.log """
svgink #{metadata.version}
Usage: #{process.argv[1]} (...options and filenames...)
Documentation: https://github.com/edemaine/svgink

Filenames should specify SVG files.
Optional arguments:
  -h / --help           Show this help message and exit.
  -o DIR / --output DIR Write all output files to directory DIR
  --os DIR / --output-svg DIR   Write all .svg files to directory DIR
  --op DIR / --output-pdf DIR   Write all .pdf files to directory DIR
  --oP DIR / --output-png DIR   Write all .png files to directory DIR
  --ot DIR / --output-tex DIR   Write all .svg_tex files to directory DIR
  -p / --pdf            Convert output SVG files to PDF via Inkscape
  -P / --png            Convert output SVG files to PNG via Inkscape
  --no-sanitize         Don't sanitize PDF output by blanking out /CreationDate
  -j N / --jobs N       Run up to N Inkscape jobs in parallel
"""

main = (args = process.argv[2..]) ->
  start = new Date
  path = require 'path'
  settings = {...defaultSettings}
  processor = new SVGProcessor settings
  formats = []
  outputDir = null
  outputDirExt = {}
  files = skip = 0
  for arg, i in args
    if skip
      skip--
      continue
    switch arg
      when '-h', '--help'
        help()
      when '-o', '--output'
        skip = 1
        outputDir = args[i+1]
      when '--op', '--output-pdf'
        skip = 1
        outputDirExt.pdf = args[i+1]
      when '--oP', '--output-png'
        skip = 1
        outputDirExt.png = args[i+1]
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
        files++
        input = arg
        for format in formats
          output = path.parse input
          delete output.base
          if output.ext != ".#{format}"
            output.ext = ".#{format}"
          else
            output.ext += ".#{format}"
          output = path.format output
          do (input, output) ->
            processor.convert input, output
            .then (data) ->
              console.log "* #{input} -> #{output}"
              console.log data.stdout if data.stdout
              console.log data.stderr if data.stderr
            .catch (error) ->
              console.log "! #{input} -> #{output} FAILED"
              console.log error
  await processor.close()
  if not formats.length
    console.log '! Not enough formats'
    help()
  else if not files
    console.log '! Not enough filename arguments'
    help()
  else
    console.log "> Converted #{files} SVG files into #{files * formats.length} files in #{Math.round((new Date) - start) / 1000} seconds"

module.exports = {
  defaultSettings
  InkscapeError
  Inkscape
  SVGProcessor
}

main() if module? and require?.main == module

#setTimeout(log, 5000).unref()
