require "cgi"

module Prouterd
  module Web
    module Helpers
      # Renders a Ruby value (the result of JSON.parse) as collapsible HTML
      # using native <details>/<summary> — no JS dependency required for
      # expand / collapse. Hashes and arrays are wrapped in <details>;
      # scalars in typed <span>s so the stylesheet can colour them by type.
      #
      # All terminal text is HTML-escaped. The caller is responsible for
      # passing only data that's safe to display (we don't redact secrets
      # here — that belongs upstream).
      module JsonTree
        DEFAULT_OPEN_DEPTH = 2

        module_function

        def render(value, open_depth: DEFAULT_OPEN_DEPTH)
          %(<div class="json">#{node(value, depth: 0, open_depth: open_depth)}</div>)
        end

        def node(value, depth:, open_depth:)
          case value
          when Hash    then hash_node(value, depth: depth, open_depth: open_depth)
          when Array   then array_node(value, depth: depth, open_depth: open_depth)
          when String  then %(<span class="json__string">"#{esc(value)}"</span>)
          when Integer then %(<span class="json__number">#{value}</span>)
          when Float   then %(<span class="json__number">#{value}</span>)
          when true    then %(<span class="json__bool">true</span>)
          when false   then %(<span class="json__bool">false</span>)
          when nil     then %(<span class="json__null">null</span>)
          else %(<span class="json__string">"#{esc(value.to_s)}"</span>)
          end
        end

        def hash_node(hash, depth:, open_depth:)
          return %(<span class="json__empty">{}</span>) if hash.empty?

          summary = %(<summary><span class="json__brace">{</span><span class="json__count">#{hash.size} #{plural("key", hash.size)}</span><span class="json__brace">}</span></summary>)
          rows = hash.map do |k, v|
            %(<div class="json__row"><span class="json__key">#{esc(k.to_s)}</span><span class="json__sep">:</span> #{node(v, depth: depth + 1, open_depth: open_depth)}</div>)
          end.join

          open_attr = depth < open_depth ? " open" : ""
          %(<details class="json__node json__node--object"#{open_attr}>#{summary}<div class="json__body">#{rows}</div></details>)
        end

        def array_node(arr, depth:, open_depth:)
          return %(<span class="json__empty">[]</span>) if arr.empty?

          summary = %(<summary><span class="json__brace">[</span><span class="json__count">#{arr.size} #{plural("item", arr.size)}</span><span class="json__brace">]</span></summary>)
          rows = arr.each_with_index.map do |v, i|
            %(<div class="json__row"><span class="json__index">#{i}</span><span class="json__sep">:</span> #{node(v, depth: depth + 1, open_depth: open_depth)}</div>)
          end.join

          open_attr = depth < open_depth ? " open" : ""
          %(<details class="json__node json__node--array"#{open_attr}>#{summary}<div class="json__body">#{rows}</div></details>)
        end

        def esc(s)
          CGI.escapeHTML(s.to_s)
        end

        def plural(noun, n)
          n == 1 ? noun : "#{noun}s"
        end
      end
    end
  end
end
