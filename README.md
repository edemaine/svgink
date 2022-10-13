# svgink: Efficiently convert SVG files to PDF or PNG via Inkscape

## Table of Contents
* [Overview](#overview)
* [Usage](#usage)
  * [Efficiency](#efficiency)
  * [Output Sanitization](#output-sanitization)
  * [Watch: Automatic Conversion of Changed SVG Files](#watch-automatic-conversion-of-changed-svg-files)
* [Installation](#installation)
* [Command-Line Interface](#command-line-interface)
* [API](#api)
  * [Examples](#examples)
  * [`SVGProcessor` Class](#svgprocessor-class)
  * [`Inkscape` Class](#inkscape-class)
  * [Settings](#settings)
  * [Events](#events)
* [Limitations](#limitations)
* [Related Work](#related-work)

## Overview

How many times have you clicked File menu / Save a Copy /
Save as type / Portable Document Format (*.pdf) / Save / OK / Replace
(in Inkscape, or similar sequences in other drawing programs),
after every edit you make to an SVG drawing?

`svgink` makes it easy to convert to PDF any changed SVG files:

```bash
svgink --pdf *.svg
# Shorthand:
svgink -p *.svg
```

For longer figure drawing sessions, you can keep `svgink` running
and watching for any changes to SVG files, automatically converting
any that you change:

```bash
# Watch for changed and new SVG files and autoconvert to PDF.
# (Quotes are necessary to enable detection of new SVG files.)
svgink --watch --pdf '*.svg'
# Watch for changed and new SVG files in any recursive subdirectory
svgink --watch --pdf '**/*.svg'
# Shorthand:
svgink -w -p '*.svg'
svgink -w -p '**/*.svg'
# Press Ctrl+C to abort a running svgink.
```

## Usage

[Inkscape](https://inkscape.org/)
can convert an SVG file into PDF or PNG using its
[command-line interface](https://wiki.inkscape.org/wiki/Using_the_Command_Line#Export_files)
like so:

```bash
# One file with custom output filename/directory:
inkscape --export-filename=output.pdf input.svg
# Multiple files with output filename/directory matching input:
inkscape --export-type=pdf filename1.svg filename2.svg
```

The `svgink` command-line tool provides a simpler command-line tool to
do the same thing, in particular evading your having to remember the exact
`--export` option format.

```bash
# Basic use, PDF mode:
svgink --pdf filename1.svg filename2.svg
# Basic use, PNG mode:
svgink --png filename1.svg filename2.svg
# Convert to both PDF and PNG:
svgink --pdf --png filename1.svg filename2.svg
# Shorthands for above three commands:
svgink -p filename1.svg filename2.svg
svgink -P filename1.svg filename2.svg
svgink -p -P filename1.svg filename2.svg
# Custom output directories:
svgink -p -o pdf filename1.svg filename2.svg
svgink -p -P --op pdf --oP png filename1.svg filename2.svg
# Force conversion even if SVG files haven't changed:
svgink -p -f filename1.svg filename2.svg
# Continuously watch for pattern of new or changed SVG files:
svgink --watch --pdf '**/*.svg'
```

### Efficiency

A major advantage of `svgink` is that it quickly converts many SVG files.

First, `svgink` skips converting SVG files that are older than the
corresponding PDF/PNG file (similar to `make`).
You can override this behavior via the `--force` command-line option,
which forces all conversions to be done.
This is useful if you update Inkscape, update `svgink`, or
a conversion failed and somehow generated a bad file.
(Alternatively, you can `touch` the relevant SVG files
or `rm` the relevant PDF/PNG files.)

Second, `svgink` uses Inkscape's
[shell protocol](https://wiki.inkscape.org/wiki/Using_the_Command_Line#Shell_mode)
to run a sequence of conversions with a single Inkscape process.
This is much faster than running Inkscape individually on each SVG file
(especially on Windows, where spawning a process takes seconds),
which is what might happen most naturally with conversions driven by `make`.

Third, `svgink` runs multiple Inkscape processes to exploit multicore CPUs.
By default, it runs half as many Inkscape processes as there are logical cores
on your machine (to account for typical hyperthreading which presents *n*
physical cores as 2&thinsp;*n* logical cores).
You can override the number of Inkscape processes to use via `-j 4` or similar.
Note that the processes are started in sequence rather than in parallel,
so you may not get full job parallelism unless you have enough jobs.
(Why in sequence?
On Windows, starting many Inkscape processes in parallel slows them all down;
and on Linux, starting Inkscape processes is fast enough to not be a big deal.
This behavior also prevents `svgink` from starting more Inkscape processes than
necessary, in case all jobs complete faster than the startup process.)

### Output Sanitization

`svgink` also tries to make version control easier with compiled PDF outputs
(which are useful to check in to avoid requiring Inkscape to build).
Normally, Inkscape includes a `/CreationDate` field in the generated PDF,
so each time you build the PDF files, the files change.
By default, `svgink` strips this date out, so the generated PDF files
should be identical across multiple runs (assuming matching Inkscape versions).
You can turn off this behavior via the `--no-sanitize` command-line option.

### Watch: Automatic Conversion of Changed SVG Files

`svgink` provides a "watch" mechanism to continuously convert files
whenever they change.  Use this when actively editing SVG files.

```bash
# Watch matching files
svgink --watch --pdf 'fig*.svg'
# Watch *.svg in all descendant directories
svgink --watch --pdf '**/*.svg'
# Watch a directory, which implicitly watches *.svg in that directory
svgink --watch --pdf figs
```

Use <kbd>Ctrl+C</kbd> to stop watching.

In the first two examples, the quotes prevent the shell from expanding
glob patterns (here, `*` and `**`) to the current list of matching files.
Without quotes, `svgink` will just detect changes to the
initial list of matching files.
Adding quotes allows `svgink` to also detect a new matching file,
e.g., a newly created `fignew.svg`.

Globs are resolved via [node-glob](https://github.com/isaacs/node-glob)
which supports [notation](https://github.com/isaacs/node-glob#glob-primer)
such as `{this,that}`, `*drawing*.svg`, `figs/**/*.svg`, etc.
On Windows, the preferred path separator for globs is forward slashes (`/`);
you can also use backward slashes (`\`), except when they would serve to escape
glob patterns.  For example, `figs\*` will be treated as the literal filename
`figs*`, while `figs/*` will be treated as "all files in directory `figs`".

To detect when globs might match new files, `svgink` watches all prefix
directories of matched files.  This may fail to detect new matching files in
a directory that previously had no matching files; in this case, `touch` any
matching directory to trigger rechecking, or restart `svgink`.

## Installation

After [installing Node](https://nodejs.org/en/download/) (v12+)
and [installing Inkscape](https://inkscape.org/release/) (v1+),
you can install this tool via

```bash
npm install -g svgink
```

This should install an `svgink` command-line tool on your path.

## Command-Line Interface

Run `svgink` to see the supported command-line options:

```
Usage: svgink (...options and filenames/directories/globs...)

Filenames or glob patterns should specify SVG files.
Directories implicitly refer to *.svg within the directory.
Optional arguments:
  -h / --help           Show this help message and exit.
  -p / --pdf            Convert SVG files to PDF via Inkscape
  -P / --png            Convert SVG files to PNG via Inkscape
  -w / --watch          Continuously watch for changed files and convert them
  -f / --force          Force conversion even if output newer than SVG input
  -o DIR / --output DIR Write all output files to directory DIR
  --op DIR / --output-pdf DIR   Write all .pdf files to directory DIR
  --oP DIR / --output-png DIR   Write all .png files to directory DIR
  -i PATH / --inkscape PATH     Specify PATH to Inkscape binary
  --no-sanitize         Don't sanitize PDF output by blanking out /CreationDate
  -j N / --jobs N       Run up to N Inkscape jobs in parallel
```

These options are intentionally similar to
[SVG Tiler](https://github.com/edemaine/svgtiler).

## API

You can also use `svgink` from your Node programs.  For example,
[SVG Tiler](https://github.com/edemaine/svgtiler) uses `svgink` to convert
generated SVG files to other formats.

First, install `svgink` as a dependency in your project:

```bash
npm install svgink
```

Then you can `require('svgink')` or `import ... from 'svgink'`.

### Examples

Here is a simple example of converting two files:

```js
import {SVGProcessor} from 'svgink';
const processor = new SVGProcessor();
processor.convert('input1.svg', 'output1.pdf')
.then(() => console.log('converted first file'));
processor.convert('input2.svg', 'output2.pdf');
.then(() => console.log('converted second file'));
await processor.close();
console.log('finished all conversions');
```

Here is a more advanced example of converting a blob specification:

```js
import {SVGProcessor} from 'svgink';
const processor = new SVGProcessor();
process.on('converted', (job) =>
  console.log(`converted ${job.input} to ${job.output}`)
);
processor.convertGlob('*.svg', ['pdf', 'png']);
await processor.close();
console.log('finished all conversions');
```

Alternatively, you can access the command-line interface
(including all printed messages) like so:

```js
import {SVGProcessor} from 'svgink';
main(['-p', '-j', '4', '-o', 'pdf', '*.svg'])
.then(() => console.log('finished all conversions'));
```

### `SVGProcessor` Class

The main interface to the API is via the `SVGProcessor` class,
which handles spawning one or more Inkscape processes
to convert one or more files or run Inkscape shell jobs.
Create one with `new SVGProcessor`
which takes an optional [settings object](#settings).
The resulting instance provides the following methods:

* `convertGlob(input, formats)` queues conversion job(s) where `input`
  can be a filename, a directory name (which means "process all `.svg`
  files in that directory"), or a glob resolving to SVG files.
  Globs are resolved via [node-glob](https://github.com/isaacs/node-glob)
  which supports [notation](https://github.com/isaacs/node-glob#glob-primer)
  such as `{this,that}`, `*drawing*.svg`, `figs/**/*.svg`, etc.
  The output `formats` should be `"pdf"`, `".pdf"`, `"png"`, `".png"`,
  another format/extension supported by Inkscape, or an array thereof.
  To be notified of conversions and/or errors, you should listen to the
  corresponding [events](#events).
* `convertTo(input, formats)` queues converting one filename to the
  specified format(s), followed by sanitizing the output.
  The `input` file should be SVG.
  The output `formats` should be `"pdf"`, `".pdf"`, `"png"`, `".png"`,
  another format/extension supported by Inkscape, or an array thereof.
  It returns a promise, or an array of promises if `formats` is an array,
  where each promise resolves to a `{skip, stdout, stderr, input, output}`
  object when the conversion and sanitization are complete.
  Here either `skip` is `true` meaning that conversion was skipped because
  the input was older than the output and `settings.force` was false, or
  `stdout` and `stderr` give the string contents from Inkscape's stdout
  and stderr for this job, which you should print to display warnings
  and/or errors.
  In addition, `input` is the original input filename,
  and `output` is the generated output filename with `format` extension.
  The promise also has an `output` property with the output filename
  in case it's needed earlier.
* `convert(input, output)` queues converting one filename to another,
  followed by sanitizing the output.  The input file should be SVG.
  The output format is determined from the file extension.
  It returns a promise which resolves to a
  `{stdout, stderr, skip, input, output}` object
  when the conversion and sanitization are complete.
* `run(job)` queues a given job.  A job can be a string to send to
  Inkscape directly, an object with a `job` string property,
  or an object of the form `{input: 'input.svg', output: `output.pdf'}`,
  but scheduling a conversion in this way will skip sanitization
  and force conversion (skip modification time checking).
  Returns a promise which resolves to a `{stdout, stderr}` object,
  along with the `job` or `input`/`output` properties from the given job,
  when the job is complete.
* `sanitize(output)` optionally sanitizes the given output filename.
  You could override this method to support custom sanitization behavior.
  It normally returns a promise.
* `watch(inputs, formats)` continuously watches for changes to the
  filename(s) in `inputs`, and when they change (and settle from changing),
  converts the file to all format(s) in `formats` (like `convertTo`).
  Each input in `inputs` can be a glob or directory name, as in `convertGlob`.
  To be notified of conversions and/or errors, you should listen to the
  corresponding [events](#events).
* `wait()` returns a promise which resolves when all jobs are complete.
  Only one `wait()` or `close()` should be active at once.
* `close()` shuts down Inkscape processes once all conversion jobs
  added so far are done.  (Do not add jobs after calling `close()`.)
  It returns a promise which resolves when all jobs are complete
  (though Inkscape processes may still be shutting down).

### `Inkscape` Class

You can also access the shell interface of a single Inkscape process
via the lower-level `Inkscape` class.
Create one with `new Inkscape`
which takes an optional [settings object](#settings).
The resulting instance provides the following methods/attributes:

* `open(initialUnref)` starts the Inkscape process.
  It returns a promise which resolves when Inkscape is ready for a job
  (has output a `> ` prompt).
  `initialUnref` specifies whether to
  [unref](https://nodejs.org/api/child_process.html#subprocessunref)
  the Inkscape process before it finishes starting;
  set true for secondary Inkscape processes.
* `run(job)` sends a given job to the Inkscape process,
  and returns a promise which resolves to a `{stdout, stderr}` object,
  along with the `job` or `input`/`output` properties from the given job,
  when Inkscape finishes the job.
  This method can be called only when Inkscape is ready
  (after the promise returned by `open()` or the last call to `run()`
  has resolved).
* `ready` is a Boolean variable indicating whether Inkscape is ready
  for a new job via `run()`.
* `close()` attempts to gently close the Inkscape process
  via the `quit` command.  If this times out,
  it kills the process via a signal.

### Settings

The constructors for `SVGProcessor` and `Inkscape` take a single optional
argument, which is a settings object.  It can have the following properties:

* `force`: Whether to force conversion, even if SVG file is older than target.
* `outputDir`: Default directory to output files via `convertTo`.
  Default = `null` which means same directory as input.
* `outputDirExt`: Object mapping from extensions (`.pdf` or `.png`) to
  directory to such output files via `convertTo`.
  Defaults = `null` which means to use `outputDir`.
* `inkscape`: Path to inkscape.  Default searches PATH for `inkscape`.
* `jobs`: Maximum number of Inkscapes to run in parallel.
  Default = half the number of logical CPUs
  (= number of physical CPU cores assuming hyperthreading).
* `idle`: If an Inkscape process sits idle for this many milliseconds,
  close it.  Default = 1 minute.  Set to `null` to disable.
* `startTimeout`: If an Inkscape fails to start shell for this many
  milliseconds, fail.  Default = 1 minute.  Set to `null` to disable.
* `quitTimeout`: If an Inkscape fails to close for this many milliseconds,
  kill it.  Default = 1 second.  Set to `null` to disable.
* `settle`: Wait for an input file to stop changing for this many milliseconds
  before watch mode triggers conversion.  Default = 1 second.
* `sanitize`: Whether to sanitize PDF output by blanking out /CreationDate.
  Default = `true`.
* `bufferSize`: Buffer size for sanitization.  Default = 16KB.

The default settings are given by the `defaultSettings` export.
If you want to override just some settings,
you should duplicate and modify that object.  For example:

```js
import {SVGProcessor, defaultSettings} from 'svgink';
const processor = new SVGProcessor({...defaultSettings, jobs: 4});
```

Alternatively, you can modify `defaultSettings` to affect all future operations:

```js
import {SVGProcessor, defaultSettings} from 'svgink';
defaultSettings.jobs = 4;
const processor = new SVGProcessor();
```

### Events

`SVGProcessor` is an [`EventEmitter`](https://nodejs.org/api/events.html)
supporting the following events:

* `'input'` indicates that an input filename has is about to be converted
  to one or more formats via `convertTo`.
  This event is most useful in the context of `convertGlob` to determine
  which (or how many) filenames matched a glob pattern or directory.
* `'converted'` indicates that a file has just been successfully converted
  and sanitized into a single format.  The event has one argument,
  a `{skip, stdout, stderr, input, output}` object as resolved from
  `convertTo`.  In particular:
  * `input` is the input filename.
  * `output` is the output filename.
  * `skip` is a Boolean indicating whether conversion was skipped because
    the input was older than the output and `settings.force` was false
  * `stdout` and `stderr` give the string contents from Inkscape's stdout
    and stderr for this job, which you should print to display warnings
    and/or errors.  They are absent if `skip` is `true`.
* `'ran'` indicates that a general Inkscape job executed by `run()` has
  successfully completed.  The event has one argument,
  an object with `input` and `output` properties as well as
  all properties from the job, as resolved from `run()`.
* `'error'` indicates that something went wrong.
  The event has one argument, which is an `Error` of some sort
  (often `InkscapeError`), and may have `input` and `output` properties
  indicating the relevant filenames for conversion.

## Limitations

Feel free to open a GitHub Issue if any of the following limitations
pose an issue for you.

* Assumes Inkscape version 1+
* Several
  [Inkscape conversion options](https://wiki.inkscape.org/wiki/Using_the_Command_Line#Export_files)
  are not yet represented by command-line options.
  For example:
  * PS, EPS, EMF, WMF, XAML conversion
  * export-dpi for PNG conversion
  * export-area-drawing instead of default export-area-page
* The Inkscape
  [shell protocol](https://wiki.inkscape.org/wiki/Using_the_Command_Line#Shell_mode)
  doesn't support filenames containing `;` or starting or ending with spaces.
  It would be possible to work around this, especially without custom output
  directories, using the command line directly.

## Related Work

There are several other packages and tools for interfacing with Inkscape
and/or converting SVG files.

* [svg2pdf](https://github.com/Savjee/svg2pdf) converts a directory of SVGs
  to a directory of PDFs, one Inkscape per job, and using threads instead of
  async.  `svgink`'s detection of default number of CPUs is based on svg2pdf's.
* [svink](https://github.com/darosh/node-svink) converts SVGs to PNGs,
  with support for lots of options corresponding to Inkscape's CLI,
  one Inkscape per job, and using threads (instead of async)
  only with multiple export IDs.  `svgink`'s name is inspired by svink's.
* [inkscape-export](https://github.com/toptensoftware/inkscape-export)
  converts SVG files to PNG at one or more scales (without parallelism),
  with additional support for multi-frame animations.
* [node-inkscape](https://github.com/papandreou/node-inkscape)
  provides a stream interface to an Inkscape process.
* [inkscape-cli](https://github.com/Kauhentus/inkscape-cli)
  provides an JavaScript interface to Inkscape's CLI.
* [svgexport](https://github.com/shakiba/svgexport) renders SVG to PNG/JPEG
  using Puppeteer.
* [svg2](https://github.com/oslllo/svg2) renders SVG to PNG using
  [resvg-js](https://github.com/yisibl/resvg-js).
