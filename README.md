bhyveucl
========

Script for starting bhyve instances based on a 
[libUCL](https://github.com/vstakhov/libucl/) config file

The tools to work with UCL from the command line is very immature, so initial
versions of this script used [jq](http://stedolan.github.io/jq/) to parse JSON
instead. See the jq branch for the old code. Generalizing the script to be
compatible with both tools is not my goal, but the old version may be useful
as a reference.

libUCL is JSON compatible, so it can read JSON config files, the advantage
to libUCL is that it is less syntax sensitive, meaning a missing or additional
comma doesn't make the config file unparsable. libUCL can also read YAML, and
nginx (bind) style config syntax. It is much more 'human writable' than JSON

Allowing a trailing comma on the last item in a JSON array or object reduces
the diff as the config file changes, which is helpful for change management.

libUCL will allow better validation of the config file by enforcing a schema.

