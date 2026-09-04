const MATCH_TYPE_LABELS: Record<string, string> = {
  // Providers — Deterministic (Tier 1)
  PROV_T0_EXACT_NPI: "Exact NPI Match",
  PROV_T1_PROVID_LICENSE: "Same Provider ID + License",
  PROV_T2_EXACT_NAME_ADDR_ZIP_TYPE: "Same Name + Address + ZIP + Provider Type",
  PROV_T3_JW_PRIMARY_ADDR_ZIP_TYPE: "Similar Name + Address + ZIP + Provider Type",
  PROV_T4_JW_SECONDARY_ADDR_ZIP_TYPE: "Similar Secondary Name + Address + ZIP + Provider Type",
  // Providers — ML (Tier 2)
  PROV_ML_MATCH: "ML Classification Match",
  // Providers — LLM (Tier 3)
  PROV_LLM_MATCH: "LLM-Confirmed Match",
  PROV_LLM_CORTEX: "LLM-Confirmed Match",
  // Recipients — Deterministic (Tier 1)
  RECIP_R0_SSN_EXACT: "Exact SSN + Date of Birth",
  RECIP_R0_SSN_DOB: "Exact SSN + Date of Birth",
  RECIP_R1_SSN4_DOB_NAME: "Same SSN Last-4 + DOB + Name",
  RECIP_R2_SSN4_NAME_ZIP: "Same SSN Last-4 + Name + ZIP",
  RECIP_R3_NAME_ADDRESS_DOB: "Same Name + Address + Date of Birth",
  RECIP_R4_NAME_DOB_ZIP: "Same Name + DOB + ZIP",
  RECIP_R5_JW_FULLNAME_ADDR_DOB: "Similar Name + Address + Date of Birth",
  RECIP_R6_DOCUMENT_SSN: "Same Document ID (Driver's License/Passport) + SSN",
  // Recipients — ML (Tier 2)
  RECIP_ML_MATCH: "ML Classification Match",
  RECIP_ML_TIER2: "ML Classification Match",
  // Recipients — LLM (Tier 3)
  RECIP_LLM_TIER3: "LLM-Confirmed Match",
}

export function humanMatchType(code: string): string {
  return MATCH_TYPE_LABELS[code] ?? code
}
