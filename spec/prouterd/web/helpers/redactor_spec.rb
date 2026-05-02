require "spec_helper"

RSpec.describe Prouterd::Web::Helpers::Redactor do
  describe ".scrub" do
    it "redacts values under sensitive keys (case-insensitive)" do
      input = { "Authorization" => "Bearer xyz", "user" => "carol" }
      expect(described_class.scrub(input))
        .to eq("Authorization" => "[REDACTED]", "user" => "carol")
    end

    it "covers a range of sensitive key shapes" do
      input = {
        "password"      => "secret",
        "API_KEY"       => "abc",
        "access_token"  => "t",
        "refresh-token" => "r",
        "client_secret" => "s",
        "Cookie"        => "session=...",
        "session_id"    => "abc123",
        "harmless"      => 42
      }
      out = described_class.scrub(input)
      expect(out["password"]).to      eq("[REDACTED]")
      expect(out["API_KEY"]).to       eq("[REDACTED]")
      expect(out["access_token"]).to  eq("[REDACTED]")
      expect(out["refresh-token"]).to eq("[REDACTED]")
      expect(out["client_secret"]).to eq("[REDACTED]")
      expect(out["Cookie"]).to        eq("[REDACTED]")
      expect(out["session_id"]).to    eq("[REDACTED]")
      expect(out["harmless"]).to      eq(42)
    end

    it "recurses through nested Hashes" do
      input = { "headers" => { "Authorization" => "Bearer x" } }
      expect(described_class.scrub(input))
        .to eq("headers" => { "Authorization" => "[REDACTED]" })
    end

    it "recurses through Arrays" do
      input = { "events" => [{ "Token" => "x" }, { "msg" => "ok" }] }
      out = described_class.scrub(input)
      expect(out["events"][0]["Token"]).to eq("[REDACTED]")
      expect(out["events"][1]["msg"]).to   eq("ok")
    end

    it "leaves non-sensitive scalar values alone" do
      expect(described_class.scrub(42)).to eq(42)
      expect(described_class.scrub("hi")).to eq("hi")
      expect(described_class.scrub(nil)).to be_nil
      expect(described_class.scrub(true)).to be true
    end
  end
end
