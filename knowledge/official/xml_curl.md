source: context7//signalwire/freeswitch-docs — mod_xml_curl dialplan/directory binding

# mod_xml_curl — dialplan and directory binding (official docs)

Retrieved via context7 MCP `query-docs` from the official FreeSWITCH docs
(/signalwire/freeswitch-docs, mirroring docs at
github.com/signalwire/freeswitch-docs/docs/integration/xml-curl.mdx).

## How XML Curl Works

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/integration/xml-curl.mdx

FreeSWITCH uses an XML registry as its runtime data store. When FreeSWITCH
needs to look up a dialplan, a directory entry, or a module configuration, it
queries the registry for the appropriate section. By default, the registry is
served from static files on disk.

`mod_xml_curl` registers a fetch handler for one or more sections. When
FreeSWITCH queries a bound section, `mod_xml_curl` makes an HTTP request to a
configured URL, passing the lookup context as POST fields. The backend must
return a well-formed XML document for that section. FreeSWITCH parses the
response and uses it in place of the static file it would otherwise read.

The binding is exclusive for the bound sections: once a section is bound to a
URL, that URL is the sole source for that section. Static files for bound
sections are not consulted.

## mod_xml_curl HTTP Request

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/integration/xml-curl.mdx

FreeSWITCH sends an HTTP POST request to the configured gateway URL to fetch
XML configuration data. The request includes core fields and optional
channel/event variables.

Request body fields:

- `hostname` (string) — the FreeSWITCH switch name.
- `section` (string) — the section being requested (e.g. `directory`,
  `dialplan`).
- `tag_name` (string) — the XML tag being searched.
- `key_name` (string) — the attribute name used for the lookup.
- `key_value` (string) — the attribute value being looked up.

## Configure xml_curl.conf.xml

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/integration/xml-curl.mdx

Define HTTP gateways within the `bindings` section of the configuration file.
Each binding is independent and can handle specific sections:

```xml
<configuration name="xml_curl.conf" description="cURL XML Gateway">
  <bindings>
    <binding name="my-backend">
      <param name="gateway-url" value="https://example.com/freeswitch/xml" bindings="directory"/>
      <param name="gateway-credentials" value="fsuser:secret"/>
      <param name="auth-scheme" value="basic"/>
      <param name="timeout" value="10"/>
    </binding>
  </bindings>
</configuration>
```

Key parameters: `gateway-url`, `gateway-credentials`, `bindings`, `method`
(plus `auth-scheme`, `timeout`).

## Dynamic Configuration with XML Curl (overview)

Source: https://github.com/signalwire/freeswitch-docs/blob/main/TABLE-OF-CONTENTS.md

Dynamic Configuration with XML Curl allows binding FreeSWITCH's
`configuration`, `directory`, and `dialplan` sections to an HTTP backend.
Key parameters include `gateway-url`, `gateway-credentials`, `bindings`, and
`method`, enabling dynamic XML serving.

## httapi Dialplan Application (related HTTP integration)

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/integration/xml-curl.mdx

`<action application="httapi" data="[URL]"/>` invokes an HTTP session to an
external backend for instruction processing. Backend POST fields include
`session_id`, `hostname`, `url`, and `exiting` (final POST only). The response
is `text/xml`, HTTP 200, in the `xml/freeswitch-httapi` document format
containing `<params>`, `<variables>`, and `<work>` elements.
