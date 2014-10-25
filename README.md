bhyveucl
========

Script for starting bhyve instances based on a libUCL config file

As the tools to work with UCL from the command line are not finished yet
the script currently uses [jq](http://stedolan.github.io/jq/) to parse JSON

libUCL is JSON compatible, so it can read JSON config files, the advantage
to libUCL is that it is less syntax sensitive, meaning a missing or additional
comma doesn't make the config file unparsable.

Allowing a trailing comma on the last item in a JSON array or object reduces
the diff as the config file changes, which is helpful for change management.

libUCL will allow better validation of the config file by enforcing a schema.

