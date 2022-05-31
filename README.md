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

First, `svgink` uses Inkscape's
[shell protocol](https://wiki.inkscape.org/wiki/Using_the_Command_Line#Shell_mode)
to run a sequence of conversions with a single Inkscape process.
This is much faster than running Inkscape individually on each SVG file
(especially on Windows, where spawning a process takes seconds),
which is what might happen most naturally with a Makefile.

Second, `svgink` runs multiple Inkscape processes to exploit multicore CPUs.
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

## Installation

After [installing Node](https://nodejs.org/en/download/),
you can install this tool via

```bash
npm install -g svgink
```

This should install an `svgink` command-line tool on your path.

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
