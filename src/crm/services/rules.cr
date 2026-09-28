# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Règles de saisie de la relation client (interne) : chaque contrôle
  # range ses erreurs sous le champ de l'entrée, avec une clé
  # `crm.errors.<objet>.<champ>.<cause>`.
  module Rules
    alias Api = Crm::Api
    alias FieldError = Partiduo::Api::FieldError

    EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      Records.error(field, key, params)
    end

    # Texte obligatoire, espaces retirés, longueur bornée.
    def self.required(value : String, field : String, object : String, max : Int32, errors : Array(FieldError)) : String
      text = value.strip
      if text.empty?
        errors << error(field, "#{object}.#{field}.blank")
      elsif text.size > max
        errors << error(field, "#{object}.#{field}.too_long", {"max" => max.to_s})
      end
      text
    end

    def self.optional(value : String, field : String, object : String, max : Int32, errors : Array(FieldError)) : String
      text = value.strip
      errors << error(field, "#{object}.#{field}.too_long", {"max" => max.to_s}) if text.size > max
      text
    end

    def self.email(value : String, field : String, object : String, errors : Array(FieldError)) : String
      text = optional(value, field, object, 254, errors).downcase
      errors << error(field, "#{object}.#{field}.invalid", {"value" => text}) unless text.empty? || text.matches?(EMAIL)
      text
    end

    def self.one_of(value : String, allowed : Array(String), field : String, object : String, errors : Array(FieldError),
                    blank : Bool = false) : String
      text = value.strip
      return text if blank && text.empty?
      errors << error(field, "#{object}.#{field}.invalid", {"value" => text}) unless allowed.includes?(text)
      text
    end

    # Référence à une ligne de paramétrage active (origine, motif).
    def self.choice(id : Int64?, model, field : String, object : String, errors : Array(FieldError)) : Int64?
      return if id.nil?
      row = model.filter(id: id).first
      errors << error(field, "#{object}.#{field}.unknown", {"value" => id.to_s}) unless row && row.active
      id
    end

    # Responsable : un utilisateur du dossier.
    def self.owner(id : Int64?, object : String, errors : Array(FieldError)) : Int64?
      return if id.nil?
      errors << error("owner_id", "#{object}.owner_id.unknown", {"value" => id.to_s}) unless Records.users.has_key?(id)
      id
    end

    # --- Organisation ------------------------------------------------------------

    def self.organization(input : Api::OrganizationInput, errors : Array(FieldError)) : Hash(String, String | Int64?)
      o = "organization"
      siren = input.siren.gsub(/\s+/, "")
      errors << error("siren", "#{o}.siren.invalid", {"value" => input.siren.strip}) unless siren.empty? || siren.matches?(/\A\d{9}\z/)
      country = input.country_code.strip.upcase
      errors << error("country_code", "#{o}.country_code.invalid", {"value" => country}) unless country.empty? || country.matches?(/\A[A-Z]{2}\z/)
      {
        "name"         => required(input.name, "name", o, 200, errors),
        "nature"       => one_of(input.nature, Api::NATURES, "nature", o, errors),
        "siren"        => siren,
        "vat_number"   => optional(input.vat_number.gsub(/\s+/, "").upcase, "vat_number", o, 32, errors),
        "email"        => email(input.email, "email", o, errors),
        "phone"        => optional(input.phone, "phone", o, 32, errors),
        "website"      => optional(input.website, "website", o, 200, errors),
        "line1"        => optional(input.line1, "line1", o, 200, errors),
        "postcode"     => optional(input.postcode, "postcode", o, 16, errors),
        "city"         => optional(input.city, "city", o, 100, errors),
        "country_code" => country,
        "notes"        => optional(input.notes, "notes", o, 10_000, errors),
        "source_id"    => choice(input.source_id, Source, "source_id", o, errors),
        "owner_id"     => owner(input.owner_id, o, errors),
      } of String => String | Int64?
    end

    def self.apply_organization(row : Organization, values : Hash(String, String | Int64?)) : Organization
      row.name = values["name"].as(String)
      row.nature = values["nature"].as(String)
      row.siren = values["siren"].as(String)
      row.vat_number = values["vat_number"].as(String)
      row.email = values["email"].as(String)
      row.phone = values["phone"].as(String)
      row.website = values["website"].as(String)
      row.line1 = values["line1"].as(String)
      row.postcode = values["postcode"].as(String)
      row.city = values["city"].as(String)
      row.country_code = values["country_code"].as(String)
      row.notes = values["notes"].as(String)
      row.source_id = values["source_id"].as(Int64?)
      row.owner_id = values["owner_id"].as(Int64?)
      row
    end

    # --- Contact -------------------------------------------------------------------

    def self.contact(input : Api::ContactInput, errors : Array(FieldError)) : Hash(String, String | Int64? | Time?)
      o = "contact"
      if (organization = input.organization_id) && Organization.filter(id: organization).first.nil?
        errors << error("organization_id", "#{o}.organization_id.unknown", {"value" => organization.to_s})
      end
      basis = one_of(input.legal_basis, Api::LEGAL_BASES, "legal_basis", o, errors, blank: true)
      basis_on = input.legal_basis_on
      basis_on ||= Records.today unless basis.empty?
      basis_on = nil if basis.empty?
      {
        "organization_id" => input.organization_id,
        "civility"        => one_of(input.civility, Api::CIVILITIES, "civility", o, errors, blank: true),
        "first_name"      => optional(input.first_name, "first_name", o, 100, errors),
        "last_name"       => required(input.last_name, "last_name", o, 100, errors),
        "job_title"       => optional(input.job_title, "job_title", o, 100, errors),
        "email"           => email(input.email, "email", o, errors),
        "phone"           => optional(input.phone, "phone", o, 32, errors),
        "mobile"          => optional(input.mobile, "mobile", o, 32, errors),
        "source_id"       => choice(input.source_id, Source, "source_id", o, errors),
        "legal_basis"     => basis,
        "legal_basis_on"  => basis_on,
        "notes"           => optional(input.notes, "notes", o, 10_000, errors),
      } of String => String | Int64? | Time?
    end

    def self.apply_contact(row : Contact, values : Hash(String, String | Int64? | Time?)) : Contact
      row.organization_id = values["organization_id"].as(Int64?)
      row.civility = values["civility"].as(String)
      row.first_name = values["first_name"].as(String)
      row.last_name = values["last_name"].as(String)
      row.job_title = values["job_title"].as(String)
      row.email = values["email"].as(String)
      row.phone = values["phone"].as(String)
      row.mobile = values["mobile"].as(String)
      row.source_id = values["source_id"].as(Int64?)
      row.legal_basis = values["legal_basis"].as(String)
      row.legal_basis_on = values["legal_basis_on"].as(Time?)
      row.notes = values["notes"].as(String)
      row
    end

    # Contact utilisable dans une action commerciale : existe et ne s'est
    # pas opposé à la prospection (ADR-009 D2).
    def self.active_contact(id : Int64?, object : String, errors : Array(FieldError),
                            organization_id : Int64? = nil) : Int64?
      return if id.nil?
      contact = Contact.filter(id: id).first
      if contact.nil?
        errors << error("contact_id", "#{object}.contact_id.unknown", {"value" => id.to_s})
      elsif contact.opposed_at
        errors << error("contact_id", "#{object}.contact_id.opposed", {"name" => "#{contact.first_name} #{contact.last_name}".strip})
      elsif organization_id && (other = contact.organization_id) && other != organization_id
        errors << error("contact_id", "#{object}.contact_id.other_organization")
      end
      id
    end

    # --- Opportunité ----------------------------------------------------------------

    def self.opportunity(input : Api::OpportunityInput, errors : Array(FieldError),
                         current : Opportunity? = nil) : Hash(String, String | Int64? | Int32 | BigDecimal | Time?)
      o = "opportunity"
      organization = Organization.filter(id: input.organization_id).first
      errors << error("organization_id", "#{o}.organization_id.unknown", {"value" => input.organization_id.to_s}) unless organization
      amount = input.amount
      if amount < 0
        errors << error("amount", "#{o}.amount.negative")
      elsif amount.scale > 2
        errors << error("amount", "#{o}.amount.scale")
      end
      stage = opportunity_stage(input, current, errors)
      probability = input.probability
      if probability && !(0..100).includes?(probability)
        errors << error("probability", "#{o}.probability.range")
      end
      probability ||= (stage.try(&.probability) || 0).to_i32
      probability = (stage.probability || 0).to_i32 if stage && stage.kind != "open"
      {
        "title"             => required(input.title, "title", o, 200, errors),
        "organization_id"   => input.organization_id.as(Int64?),
        "contact_id"        => active_contact_unless_kept(input.contact_id, current, o, errors, input.organization_id),
        "amount"            => amount.round(2),
        "probability"       => probability,
        "expected_close_on" => input.expected_close_on,
        "owner_id"          => owner(input.owner_id, o, errors),
        "stage_id"          => stage.try(&.id).try(&.to_i64),
        "source_id"         => choice(input.source_id, Source, "source_id", o, errors),
      } of String => String | Int64? | Int32 | BigDecimal | Time?
    end

    # Étape d'une opportunité : la sienne (modification), celle demandée à
    # la création (étape de travail active) ou la première étape de travail.
    private def self.opportunity_stage(input : Api::OpportunityInput, current : Opportunity?,
                                       errors : Array(FieldError)) : Stage?
      return Records.stage!(current.stage_id!.to_i64) if current
      id = input.stage_id
      return Records.first_open_stage if id.nil?
      found = Stage.filter(id: id).first
      if found.nil? || !found.active || found.kind != "open"
        errors << error("stage_id", "opportunity.stage_id.invalid", {"value" => id.to_s})
      end
      found
    end

    # Le contact déjà porté par l'opportunité reste admis même s'il s'est
    # opposé depuis (on ne réécrit pas l'histoire) ; un nouveau contact doit
    # être utilisable.
    private def self.active_contact_unless_kept(id : Int64?, current : Opportunity?, object : String,
                                                errors : Array(FieldError), organization_id : Int64) : Int64?
      return id if id && current && current.contact_id == id
      active_contact(id, object, errors, organization_id)
    end

    def self.apply_opportunity(row : Opportunity, values : Hash(String, String | Int64? | Int32 | BigDecimal | Time?)) : Opportunity
      row.title = values["title"].as(String)
      row.organization_id = values["organization_id"].as(Int64?)
      row.contact_id = values["contact_id"].as(Int64?)
      row.amount = values["amount"].as(BigDecimal)
      row.probability = values["probability"].as(Int32)
      row.expected_close_on = values["expected_close_on"].as(Time?)
      row.owner_id = values["owner_id"].as(Int64?)
      row.stage_id = values["stage_id"].as(Int64?)
      row.source_id = values["source_id"].as(Int64?)
      row
    end

    # --- Activité -------------------------------------------------------------------

    def self.activity(input : Api::ActivityInput, errors : Array(FieldError)) : Hash(String, String | Int64? | Int32? | Bool | Time?)
      o = "activity"
      if (organization = input.organization_id) && Organization.filter(id: organization).first.nil?
        errors << error("organization_id", "#{o}.organization_id.unknown", {"value" => organization.to_s})
      end
      if (opportunity = input.opportunity_id) && Opportunity.filter(id: opportunity).first.nil?
        errors << error("opportunity_id", "#{o}.opportunity_id.unknown", {"value" => opportunity.to_s})
      end
      if input.organization_id.nil? && input.contact_id.nil? && input.opportunity_id.nil?
        errors << error(FieldError::BASE, "#{o}.target.missing")
      end
      duration = input.duration_minutes
      errors << error("duration_minutes", "#{o}.duration_minutes.range") if duration && !(0..14_400).includes?(duration)
      kind = one_of(input.kind, Api::ACTIVITY_KINDS, "kind", o, errors)
      {
        "kind"             => kind,
        "subject"          => required(input.subject, "subject", o, 200, errors),
        "due_on"           => input.due_on || Records.today,
        "starts_at"        => input.starts_at,
        "duration_minutes" => duration,
        "owner_id"         => owner(input.owner_id, o, errors),
        "report"           => optional(input.report, "report", o, 20_000, errors),
        "done"             => input.done || kind == "note",
        "organization_id"  => input.organization_id,
        "contact_id"       => active_contact(input.contact_id, o, errors),
        "opportunity_id"   => input.opportunity_id,
      } of String => String | Int64? | Int32? | Bool | Time?
    end

    def self.apply_activity(row : Activity, values : Hash(String, String | Int64? | Int32? | Bool | Time?)) : Activity
      row.kind = values["kind"].as(String)
      row.subject = values["subject"].as(String)
      row.due_on = values["due_on"].as(Time?)
      row.starts_at = values["starts_at"].as(Time?)
      row.duration_minutes = values["duration_minutes"].as(Int32?)
      row.owner_id = values["owner_id"].as(Int64?)
      row.report = values["report"].as(String)
      done = values["done"].as(Bool)
      row.done_at = done ? (row.done_at || Time.utc) : nil
      row.done = done
      row.organization_id = values["organization_id"].as(Int64?)
      row.contact_id = values["contact_id"].as(Int64?)
      row.opportunity_id = values["opportunity_id"].as(Int64?)
      row
    end
  end
end
