#Ruby API for mgrep

The class `Annotator::Mgrep::Client` encapsulates the interactions with mgrep. To instantiate this client use:

```
client = Annotator::Mgrep::Client.new(Annotator.settings.mgrep_host, Annotator.settings.mgrep_port, Annotator.settings.mgrep_alt_host, Annotator.settings.mgrep_alt_port)
```

**Notice:** This client is not thread safe, one cannot get hold of a reference an use it in a multi-threaded environment. You can pipeline multiple annotation calls, that is safe. One could also instantiate multiple clients and make concurrent calls to a mgrep server.


Once you have instantiated the client there is one main function to call when annotating text:

```
client.annotate(text,longword)
```

The first parameter `text` is the text to be annotated. Internally it will be transformed into an upper case string with no lines. No need to do this transformation prior to the call.

The second paramter `longword` is a boolean parameter. If `true` mgrep will match the longest occurrences ONLY, if `false` mgrep will match all occurrences.

`client.annotate` returns an `AnnotatedText` object. This is essentially a collection of annotations. One can iterate over all annotations using `each`. 

Each annotation is a `Struct` with the following fields:

* `offset_from` position of the first character of the annotation.
* `offset_to` position of the last character of the annotation.
* `string_id` mgrep string id. The dictionary value for the term.
* `value` string value of the annotation in the text.

## A complete example


```
client = Annotator::Mgrep::Client.new(Annotator.settings.mgrep_host, Annotator.settings.mgrep_port, Annotator.settings.mgrep_alt_host, Annotator.settings.mgrep_alt_port)
annotations = client.annotate("Legal occupations Officer of the court",true)
annotations.each do |ann|
  puts ann.offset_from
  puts ann.offset_to
  puts ann.string_id
  puts ann.value
end
client.close()
```
