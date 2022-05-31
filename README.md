# svgink: Efficiently convert SVG files to PDF or PNG via Inkscape

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
do the same thing:

```bash
# Basic use:
svgink --pdf filename1.svg filename2.svg
# Short-hand:
svgink -p filename1.svg filename2.svg
# Custom output directory:
svgink --pdf -o pdf filename1.svg filename2.svg
```

## Efficiency

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
physical cores as 2&nbsp;*n* logical cores).
You can override the number of Inkscape processes to use via `-j 4` or similar.
Note that the processes are started in sequence rather than in parallel,
so you may not get full job parallelism unless you have enough jobs.
(On Windows, starting many Inkscape processes in parallel slows them all down;
and on Linux, starting Inkscape processes is fast enough to not be a big deal.
This also prevents `svgink` from starting more Inkscape processes than
necessary, in case all jobs complete faster than the startup process.)

## Sanitization

`svgink` also tries to make version control easier with compiled PDF outputs
(which are useful to check in to avoid requiring Inkscape to build).
Normally, Inkscape includes a `/CreationDate` field in the generated PDF,
so each time you build the PDF files, the files change.
By default, `svgink` strips this date out, so the generated PDF files
should be identical (assuming matching Inkscape versions).
You can turn off this behavior via the `--no-sanitize` command-line option.

## Installation

After [installing Node](https://nodejs.org/en/download/),
you can install this tool via

```bash
npm install -g svgink
```

This should install an `svgink` command-line tool on your path.

## Command-Line Interface

Run `svgink` to see the supported command-line options:

```
Usage: svgink (...options and filenames...)

Filenames should specify SVG files.
Optional arguments:
  -h / --help           Show this help message and exit.
  -f / --force          Force conversion even if output newer than SVG input
  -o DIR / --output DIR Write all output files to directory DIR
  --op DIR / --output-pdf DIR   Write all .pdf files to directory DIR
  --oP DIR / --output-png DIR   Write all .png files to directory DIR
  -p / --pdf            Convert output SVG files to PDF via Inkscape
  -P / --png            Convert output SVG files to PNG via Inkscape
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

Alternatively, you can access the command-line interface like so:

```js
import {SVGProcessor} from 'svgink';
main(['-p', '-j', '4', '-o', 'pdf', 'input1.svg', 'input2.svg'])
.then(() => console.log('finished all conversions'));
```

The API provides two classes:

1. `SVGProcessor` handles spawning one or more Inkscape processes.
   * `convertTo(input, format)` queues converting one filename to the
     specified format, followed by sanitizing the output.
     The `input` file should be SVG.
     The output `format` should be `"pdf"`, `".pdf"`, `"png"`, `".png"`,
     or another format/extension supported by Inkscape;
     It returns a promise which resolves to a
     `{skip, stdout, stderr, input, output}`
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
   * `close()` shuts down Inkscape processes once all conversion jobs
     added so far are done.  (Do not add jobs after calling `close()`.)
     It returns a promise which resolves when all jobs are complete
     (though Inkscape processes may still be shutting down).
2. `Inkscape` handles interaction with a single Inkscape process
   (via its shell interface).
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
  close it.  Default = `null` which means infinity.
* `startTimeout`: If an Inkscape fails to start shell for this many
  milliseconds, fail.  Default = 5 seconds.  Set to `null` to disable.
* `quitTimeout`: If an Inkscape fails to close for this many milliseconds,
  kill it.  Default = 1 second.  Set to `null` to disable.
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
  * export-area-drawing instad of default export-area-page
* The Inkscape
  [shell protocol](https://wiki.inkscape.org/wiki/Using_the_Command_Line#Shell_mode)
  doesn't support filenames containing `;` or starting or ending with spaces.
  It would be possible to work around this, especially without custom output
  directories, using the command line directly.
