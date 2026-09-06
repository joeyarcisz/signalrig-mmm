/**
 * Bundled sample handoff packages, generated programmatically so the Data
 * Drop-In moment works on stage even if drag-and-drop misbehaves. The "valid"
 * package mirrors the synthetic twin's shape (104 weeks, 8 channels); the
 * "broken" package reproduces the failure modes the validator must catch.
 */

const CHANNELS: Array<[string, string, number, number]> = [
  // channel, platform, weekly spend base, cpm
  ["google_search", "Google Ads", 4200, 0],
  ["meta", "Meta", 4800, 12],
  ["tiktok", "TikTok", 2400, 10],
  ["military_publishers", "audience publisher", 1800, 18],
  ["youtube", "YouTube", 1700, 14],
  ["programmatic_display", "DV360", 1300, 10],
  ["streaming_audio", "Spotify", 1500, 18],
  ["mntn_ctv", "MNTN", 1100, 30],
];

function mondays(count: number, endIso: string): string[] {
  const end = new Date(`${endIso}T00:00:00Z`);
  const out: string[] = [];
  for (let i = count - 1; i >= 0; i--) {
    const d = new Date(end.getTime() - i * 7 * 86400000);
    out.push(d.toISOString().slice(0, 10));
  }
  return out;
}

function seedRand(seed: number) {
  let s = seed;
  return () => ((s = (s * 1103515245 + 12345) % 2147483648), s / 2147483648);
}

export function buildValidPackage(): Record<string, string> {
  const weeks = mondays(104, "2026-06-08");
  const rand = seedRand(7);

  const kpiLines = ["date_week,geo,kpi_name,kpi_value,revenue_per_kpi"];
  weeks.forEach((w, i) => {
    const season = 1 + 0.1 * Math.sin((i / 52) * 2 * Math.PI + 1.1);
    const value = Math.round(450 * season * (0.92 + rand() * 0.16));
    kpiLines.push(`${w},US,caregiver_signups,${value},120`);
  });

  const pmLines = ["date_week,geo,channel,campaign,platform,spend,impressions,clicks"];
  weeks.forEach((w, i) => {
    for (const [channel, platform, base, cpm] of CHANNELS) {
      const flight = channel === "mntn_ctv" || channel === "streaming_audio" ? (Math.floor(i / 6) % 2 === 0 ? 1 : 0.15) : 1;
      const spend = Math.round(base * flight * (0.75 + rand() * 0.5));
      const impressions = cpm > 0 ? Math.round((spend / cpm) * 1000) : Math.round(spend * 9);
      const clicks = Math.max(1, Math.round(impressions * (0.002 + rand() * 0.008)));
      pmLines.push(`${w},US,${channel},${channel}_evergreen,${platform},${spend},${impressions},${clicks}`);
    }
  });

  const organicLines = ["date_week,geo,source,exposure_metric,exposure_value"];
  weeks.forEach((w) => {
    organicLines.push(`${w},US,email,sends,${Math.round(20000 * (0.8 + rand() * 0.4))}`);
    organicLines.push(`${w},US,owned_site,sessions,${Math.round(34000 * (0.8 + rand() * 0.4))}`);
  });

  const controlLines = ["date_week,geo,control_name,control_value"];
  weeks.forEach((w, i) => {
    controlLines.push(`${w},US,military_pcs_season,${i % 52 > 18 && i % 52 < 34 ? 1 : 0}`);
    controlLines.push(`${w},US,unemployment_idx,${(3.9 + Math.sin(i / 9) * 0.4).toFixed(2)}`);
  });

  return {
    "kpi.csv": kpiLines.join("\n"),
    "paid_media.csv": pmLines.join("\n"),
    "organic_owned.csv": organicLines.join("\n"),
    "controls.csv": controlLines.join("\n"),
  };
}

export function buildBrokenPackage(): Record<string, string> {
  const weeks = mondays(18, "2026-06-08");
  const rand = seedRand(11);

  const kpiLines = ["date_week,geo,kpi_name,kpi_value"];
  weeks.forEach((w, i) => {
    // two malformed dates and one nonnumeric KPI value
    const date = i === 4 ? "06/15/2026" : i === 9 ? "2026-13-01" : w;
    const value = i === 6 ? "n/a" : String(Math.round(400 * (0.9 + rand() * 0.2)));
    kpiLines.push(`${date},US,caregiver_signups,${value}`);
  });
  // duplicate key row
  kpiLines.push(kpiLines[1]);

  // paid_media is missing the spend column entirely (the classic export miss)
  const pmLines = ["date_week,geo,channel,campaign,platform,impressions,clicks"];
  weeks.forEach((w) => {
    for (const [channel, platform] of [
      ["meta", "Meta"],
      ["google_search", "Google Ads"],
      ["tiktok", "TikTok"],
    ] as Array<[string, string]>) {
      const impressions = Math.round(200000 * (0.7 + rand() * 0.6));
      pmLines.push(`${w},US,${channel},${channel}_q2,${platform},${impressions},${Math.round(impressions * 0.008)}`);
    }
  });

  return {
    "kpi.csv": kpiLines.join("\n"),
    "paid_media.csv": pmLines.join("\n"),
  };
}
