require "rails_helper"
require Rails.root.join("bench/collect").to_s

# The scoring and knee-selection rules decide every published number, so they
# are tested directly rather than through k6.
RSpec.describe Collect do
  describe ".score" do
    it "counts RPS when the p95 held the SLO" do
      result = described_class.score({ "p95_ms" => 150.0, "rps" => 40.0 }, 200, 10.0, 20.0)

      expect(result["met_slo"]).to be true
      expect(result["rps_eff"]).to eq(40.0)
      expect(result["rps_per_usd"]).to eq(4.0)
      expect(result["rps_per_usd_total"]).to eq(2.0)
    end

    it "throws the RPS away when the p95 broke the SLO" do
      # Fast-and-wrong must not outrank correct-and-slower.
      result = described_class.score({ "p95_ms" => 900.0, "rps" => 500.0 }, 200, 10.0, 20.0)

      expect(result["met_slo"]).to be false
      expect(result["rps_eff"]).to eq(0.0)
      expect(result["rps_per_usd"]).to eq(0.0)
    end

    it "treats a p95 exactly at the SLO as holding" do
      result = described_class.score({ "p95_ms" => 200.0, "rps" => 10.0 }, 200, 10.0, 10.0)

      expect(result["met_slo"]).to be true
    end

    it "reports no cost ratio when the tier has no price" do
      result = described_class.score({ "p95_ms" => 10.0, "rps" => 10.0 }, 200, nil, nil)

      expect(result["rps_per_usd"]).to be_nil
      expect(result["rps_per_usd_total"]).to be_nil
    end

    it "scores a run that returned no p95 as a failure rather than a pass" do
      result = described_class.score({ "p95_ms" => nil, "rps" => nil }, 200, 10.0, 10.0)

      expect(result["met_slo"]).to be false
      expect(result["rps_eff"]).to eq(0.0)
    end
  end

  describe ".select_knee" do
    def step(rate, met) = { "target_rps" => rate, "met_slo" => met, "rps" => rate.to_f }

    it "picks the highest rate that held the SLO" do
      ladder = [step(5, true), step(10, true), step(25, false)]

      knee = described_class.select_knee(ladder)

      expect(knee["target_rps"]).to eq(10)
      expect(knee["met_slo"]).to be true
      expect(knee["ladder"]).to eq(ladder)
    end

    it "flags that the ceiling was never found when every rate held" do
      # Otherwise a ladder that stopped too low reads as the platform's limit.
      knee = described_class.select_knee([step(5, true), step(10, true)])

      expect(knee["target_rps"]).to eq(10)
      expect(knee["knee_not_found"]).to be true
    end

    it "does not flag knee_not_found once a rate has broken" do
      knee = described_class.select_knee([step(5, true), step(10, false)])

      expect(knee).not_to have_key("knee_not_found")
    end

    it "reports the gentlest rate, still failing, when nothing held" do
      knee = described_class.select_knee([step(5, false)])

      expect(knee["target_rps"]).to eq(5)
      expect(knee["met_slo"]).to be false
    end

    it "returns nothing for an empty ladder" do
      expect(described_class.select_knee([])).to eq({})
    end
  end

  describe ".parse_summary" do
    it "reads p95, rate and success rate out of a k6 summary" do
      summary = {
        "metrics" => {
          "http_req_duration" => { "values" => { "p(95)" => 57.1 } },
          "server_ms" => { "values" => { "p(95)" => 12.1 } },
          "http_reqs" => { "values" => { "rate" => 7.47 } },
          "endpoint_ok" => { "values" => { "rate" => 1 } }
        }
      }

      expect(described_class.parse_summary(summary)).to eq(
        "p95_ms" => 57.1, "server_p95_ms" => 12.1, "queue_and_network_p95_ms" => 45.0,
        "rps" => 7.47, "ok_rate" => 1
      )
    end

    # Separating app time from queue time is the whole reason server_ms exists;
    # a 10s wall time on a 20ms app call means the box is full, not slow.
    it "splits wall time into app time and queue/network time" do
      summary = {
        "metrics" => {
          "http_req_duration" => { "values" => { "p(95)" => 10_000.0 } },
          "server_ms" => { "values" => { "p(95)" => 20.0 } }
        }
      }

      expect(described_class.parse_summary(summary)["queue_and_network_p95_ms"]).to eq(9980.0)
    end

    it "omits the split when the app reported no server_ms" do
      summary = { "metrics" => { "http_req_duration" => { "values" => { "p(95)" => 57.1 } } } }

      expect(described_class.parse_summary(summary)).not_to have_key("queue_and_network_p95_ms")
    end
  end
end
