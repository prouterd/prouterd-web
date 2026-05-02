require "spec_helper"

RSpec.describe Prouterd::Web::Helpers::JsonTree do
  subject(:render) { ->(value, **opts) { described_class.render(value, **opts) } }

  it "wraps the result in a .json container" do
    expect(render.call({})).to start_with('<div class="json">')
  end

  it "renders an empty hash as a non-collapsible marker" do
    expect(render.call({})).to include('class="json__empty"')
    expect(render.call({})).to include("{}")
  end

  it "uses native <details> for non-empty hashes, opening top levels by default" do
    html = render.call({ "a" => 1, "b" => "two" })
    expect(html).to include("<details")
    expect(html).to include(' open')
    expect(html).to include('class="json__key">a')
    expect(html).to include('class="json__number">1')
    expect(html).to include('class="json__string">"two"')
  end

  it "indexes array items" do
    html = render.call(%w[x y])
    expect(html).to include('class="json__index">0')
    expect(html).to include('class="json__index">1')
    expect(html).to include('class="json__string">"x"')
  end

  it "escapes HTML in keys and values" do
    html = render.call({ "<k>" => "<v>" })
    expect(html).to include("&lt;k&gt;")
    expect(html).to include("&lt;v&gt;")
    expect(html).not_to include("<k>")
  end

  it "renders booleans and null with typed spans" do
    html = render.call({ "ok" => true, "missing" => nil, "neg" => false })
    expect(html).to include('class="json__bool">true')
    expect(html).to include('class="json__bool">false')
    expect(html).to include('class="json__null">null')
  end

  it "respects open_depth to keep deeper nodes collapsed" do
    deep = { "a" => { "b" => { "c" => 1 } } }
    html = render.call(deep, open_depth: 1)
    # Outer node opens, inner collapses
    open_count = html.scan(/<details[^>]* open/).size
    expect(open_count).to eq(1)
  end
end
