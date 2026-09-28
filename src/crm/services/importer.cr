# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Import CSV des organisations et contacts (ADR-009 D8) : séparateur
  # reconnu (`;`, `,` ou tabulation), correspondance des colonnes proposée
  # d'après les en-têtes (fr, en, nl), aperçu ligne par ligne, doublons
  # signalés par SIREN, courriel ou nom — et écartés à l'import. Interne.
  module Importer
    alias Api = Crm::Api
    alias FieldError = Partiduo::Api::FieldError

    MAX_ROWS = 5000

    # En-têtes reconnus (repliés : minuscules, sans accents ni ponctuation).
    SYNONYMS = {
      "organization_name"       => %w[organisation organization organisatie societe entreprise company bedrijf raisonsociale nomorganisation organisationname],
      "organization_nature"     => %w[nature naturedelorganisation organizationnature aard type],
      "organization_siren"      => %w[siren sirennumber],
      "organization_vat_number" => %w[tva numerotva notva vat vatnumber btw btwnummer tvaintracommunautaire],
      "organization_email"      => %w[courrielorganisation emailorganisation courrielsociete emailsociete companyemail organisationemail],
      "organization_phone"      => %w[telephoneorganisation telephonesociete standard companyphone organisationtelefoon],
      "organization_website"    => %w[site siteweb siteinternet website web url],
      "organization_line1"      => %w[adresse address adres rue street straat],
      "organization_postcode"   => %w[codepostal cp postcode zip zipcode postalcode],
      "organization_city"       => %w[ville city commune gemeente stad plaats],
      "organization_country"    => %w[pays country land codepays countrycode],
      "contact_civility"        => %w[civilite civility aanspreking salutation],
      "contact_first_name"      => %w[prenom firstname givenname voornaam],
      "contact_last_name"       => %w[nom lastname surname familyname achternaam familienaam naam nomdefamille],
      "contact_job_title"       => %w[fonction poste jobtitle title functie],
      "contact_email"           => %w[email courriel mail emailaddress adressecourriel emailadres],
      "contact_phone"           => %w[telephone tel phone telefoon telefoonnummer],
      "contact_mobile"          => %w[mobile portable gsm mobiel cellphone],
      "source"                  => %w[origine source bron],
      "legal_basis"             => %w[baselegale legalbasis rechtsgrond],
      "notes"                   => %w[notes remarques commentaire commentaires comment opmerkingen notities],
    }

    def self.fold(text : String) : String
      text.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "")
    end

    # Séparateur le plus fréquent de la première ligne.
    def self.separator(content : String) : Char
      first = content.each_line.first? || ""
      [';', ',', '\t'].max_by { |candidate| first.count(candidate) }
    end

    # En-têtes et lignes du fichier (BOM retiré), chaque ligne avec son
    # numéro dans le fichier (en-tête = 1) ; les lignes vides sont sautées.
    def self.parse(content : String) : {Array(String), Array({Array(String), Int32}), Char}
      text = content.lchop('\uFEFF')
      sep = separator(text)
      rows = CSV.parse(text, separator: sep)
      headers = (rows.shift? || [] of String).map(&.strip)
      numbered = rows.map_with_index { |cells, index| {cells, index + 2} }.reject(&.[0].all?(&.strip.empty?))
      {headers, numbered, sep}
    end

    def self.propose(headers : Array(String)) : Hash(String, String)
      used = Set(String).new
      headers.to_h do |header|
        folded = fold(header)
        field = Api::IMPORT_FIELDS.find { |name| !used.includes?(name) && (fold(name) == folded || SYNONYMS[name]?.try(&.includes?(folded))) }
        used << field if field
        {header, field || ""}
      end
    end

    def self.preview(input : Api::ImportInput) : Api::ImportPreviewView | Array(FieldError)
      headers, rows, sep = parse(input.content)
      return [Records.error("content", "import.content.empty")] if headers.empty? || rows.empty?
      return [Records.error("content", "import.content.too_many", {"max" => MAX_ROWS.to_s})] if rows.size > MAX_ROWS
      mapping = input.mapping || propose(headers)
      unknown = mapping.values.reject { |field| field.empty? || Api::IMPORT_FIELDS.includes?(field) }
      return [Records.error("mapping", "import.mapping.invalid", {"value" => unknown.first})] unless unknown.empty?
      mapped = mapping.values.reject(&.empty?)
      duplicate_field = mapped.find { |field| mapped.count(field) > 1 }
      return [Records.error("mapping", "import.mapping.twice", {"value" => duplicate_field})] if duplicate_field
      unless mapped.includes?("organization_name") || mapped.includes?("contact_last_name")
        return [Records.error("mapping", "import.mapping.name_missing")]
      end

      seen_emails = {} of String => Int32
      seen_organizations = {} of String => String
      views = rows.map do |(cells, line)|
        values = {} of String => String
        headers.each_with_index do |header, index|
          field = mapping[header]?.presence || next
          values[field] = cells[index]?.try(&.strip) || ""
        end
        check_row(line, values, input, seen_emails, seen_organizations)
      end
      Api::ImportPreviewView.new(headers, mapping, sep, views)
    end

    # Contrôle d'une ligne : saisies valides (mêmes règles que les écrans),
    # doublon dans le dossier ou plus haut dans le fichier.
    private def self.check_row(line : Int32, values : Hash(String, String), input : Api::ImportInput,
                               seen_emails : Hash(String, Int32), seen_organizations : Hash(String, String)) : Api::ImportRowView
      errors = [] of FieldError
      name = values["organization_name"]?.to_s
      last_name = values["contact_last_name"]?.to_s
      if name.empty? && last_name.empty?
        errors << Records.error(FieldError::BASE, "import.row.empty")
        return Api::ImportRowView.new(line, values, nil, nil, errors)
      end
      unless name.empty?
        found = [] of FieldError
        Rules.organization(organization_input(values), found)
        errors.concat(found.map { |error| FieldError.new("organization_#{error.field}", error.key, error.params) })
      end
      unless last_name.empty?
        found = [] of FieldError
        Rules.contact(contact_input(values, nil, input), found)
        errors.concat(found.map { |error| FieldError.new("contact_#{error.field}", error.key, error.params) })
      end
      duplicate, duplicate_of = duplicate(values, seen_emails, seen_organizations, line)
      Api::ImportRowView.new(line, values, duplicate, duplicate_of, errors)
    end

    private def self.duplicate(values : Hash(String, String), seen_emails : Hash(String, Int32),
                               seen_organizations : Hash(String, String), line : Int32) : {String?, String?}
      found = organization_duplicate(values, seen_organizations)
      return found if found[0]
      contact_duplicate(values, seen_emails, line)
    end

    # Organisation déjà suivie (même SIREN, sinon même nom), ou même SIREN
    # qu'une autre organisation du fichier sous un autre nom.
    private def self.organization_duplicate(values : Hash(String, String),
                                            seen_organizations : Hash(String, String)) : {String?, String?}
      siren = values["organization_siren"]?.to_s.gsub(/\s+/, "")
      name = values["organization_name"]?.to_s.strip
      if !siren.empty? && (same_siren = Organization.filter(siren: siren).first)
        return {"siren", same_siren.name.to_s}
      end
      if !name.empty? && (same_name = Organization.filter(name__iexact: name).first)
        return {"organization_name", same_name.name.to_s}
      end
      return {nil, nil} if siren.empty?
      if (other = seen_organizations[siren]?) && fold(other) != fold(name)
        return {"siren", other}
      end
      seen_organizations[siren] = name
      {nil, nil}
    end

    # Contact déjà suivi (même courriel, sinon même prénom et nom sans
    # courriel), ou même courriel plus haut dans le fichier.
    private def self.contact_duplicate(values : Hash(String, String), seen_emails : Hash(String, Int32),
                                       line : Int32) : {String?, String?}
      email = values["contact_email"]?.to_s.strip.downcase
      last_name = values["contact_last_name"]?.to_s.strip
      first_name = values["contact_first_name"]?.to_s.strip
      unless email.empty?
        if same_email = Contact.filter(email__iexact: email).first
          return {"contact_email", "#{same_email.first_name} #{same_email.last_name}".strip}
        end
        return {"file_email", seen_emails[email].to_s} if seen_emails.has_key?(email)
        seen_emails[email] = line
        return {nil, nil}
      end
      return {nil, nil} if last_name.empty?
      same_person = Contact.filter(last_name__iexact: last_name, first_name__iexact: first_name).first
      same_person ? {"contact_name", "#{same_person.first_name} #{same_person.last_name}".strip} : {nil, nil}
    end

    # Importe les lignes sans doublon ni erreur ; les organisations de même
    # nom dans le fichier n'en font qu'une.
    def self.import!(actor : Partiduo::Api::Actor, preview : Api::ImportPreviewView,
                     input : Api::ImportInput) : Api::ImportReportView
      created = {} of String => Int64
      organizations = 0
      contacts = 0
      preview.rows.each do |row|
        next unless row.importable?
        values = row.values
        organization_id = nil
        name = values["organization_name"]?.to_s
        unless name.empty?
          organization_id = created[fold(name)]? || begin
            errors = [] of FieldError
            fields = Rules.organization(organization_input(values), errors)
            raise "crm : ligne #{row.line} refusée après l'aperçu" unless errors.empty?
            organization = Rules.apply_organization(Organization.new(created_by_id: actor.user_id), fields)
            organization.owner_id ||= actor.user_id
            organization.save!
            organizations += 1
            created[fold(name)] = organization.id!.to_i64
          end
        end
        next if values["contact_last_name"]?.to_s.empty?
        errors = [] of FieldError
        fields = Rules.contact(contact_input(values, organization_id, input), errors)
        raise "crm : ligne #{row.line} refusée après l'aperçu" unless errors.empty?
        Rules.apply_contact(Contact.new, fields).save!
        contacts += 1
      end
      Api::ImportReportView.new(organizations, contacts, preview.rows.reject(&.importable?))
    end

    private def self.organization_input(values : Hash(String, String)) : Api::OrganizationInput
      nature = choice_code(values["organization_nature"]?.to_s, Api::NATURES, "crm.natures") || "business"
      Api::OrganizationInput.new(
        name: values["organization_name"]?.to_s, nature: nature, siren: values["organization_siren"]?.to_s,
        vat_number: values["organization_vat_number"]?.to_s, email: values["organization_email"]?.to_s,
        phone: values["organization_phone"]?.to_s, website: values["organization_website"]?.to_s,
        line1: values["organization_line1"]?.to_s, postcode: values["organization_postcode"]?.to_s,
        city: values["organization_city"]?.to_s, country_code: values["organization_country"]?.to_s,
        source_id: source_id(values["source"]?.to_s), notes: values["notes"]?.to_s,
      )
    end

    private def self.contact_input(values : Hash(String, String), organization_id : Int64?,
                                   input : Api::ImportInput) : Api::ContactInput
      basis = choice_code(values["legal_basis"]?.to_s, Api::LEGAL_BASES, "crm.legal_bases") || input.legal_basis
      Api::ContactInput.new(
        last_name: values["contact_last_name"]?.to_s, first_name: values["contact_first_name"]?.to_s,
        organization_id: organization_id,
        civility: choice_code(values["contact_civility"]?.to_s, Api::CIVILITIES, "crm.civilities") || "",
        job_title: values["contact_job_title"]?.to_s, email: values["contact_email"]?.to_s,
        phone: values["contact_phone"]?.to_s, mobile: values["contact_mobile"]?.to_s,
        source_id: source_id(values["source"]?.to_s) || input.source_id, legal_basis: basis,
        notes: values["organization_name"]?.to_s.empty? ? values["notes"]?.to_s : "",
      )
    end

    # Code d'une valeur saisie : le code lui-même ou son libellé dans une
    # des trois langues ; `nil` si rien ne correspond.
    private def self.choice_code(value : String, codes : Array(String), scope : String) : String?
      folded = fold(value)
      return if folded.empty?
      codes.find do |code|
        fold(code) == folded || Partiduo::LOCALES.any? { |locale| I18n.with_locale(locale) { fold(I18n.t("#{scope}.#{code}")) == folded } }
      end
    end

    # Origine : par code ou par libellé (nom, ou traduction d'une valeur
    # initiale) ; `nil` si inconnue.
    private def self.source_id(value : String) : Int64?
      folded = fold(value)
      return if folded.empty?
      Source.filter(active: true).to_a.find do |row|
        fold(row.code.to_s) == folded || fold(row.name.to_s) == folded ||
          (!row.code.to_s.empty? && Partiduo::LOCALES.any? { |locale| I18n.with_locale(locale) { fold(I18n.t("crm.sources.#{row.code}")) == folded } })
      end.try(&.id).try(&.to_i64)
    end
  end
end
