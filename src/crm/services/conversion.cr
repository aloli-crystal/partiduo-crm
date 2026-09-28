# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  # Du prospect au client et de l'opportunité au devis (ADR-009 D2, D5),
  # par le contrat du cœur seulement : `Partiduo::Api::Cards` crée la fiche
  # client, `Partiduo::Api::Invoicing.create_document` le devis brouillon.
  # Interne ; appelé dans la transaction de la commande.
  module Conversion
    alias FieldError = Partiduo::Api::FieldError
    alias Cards = Partiduo::Api::Cards
    alias Inv = Partiduo::Api::Invoicing

    # Organisation en cours de conversion, par fibre : l'abonné de
    # `card.saved`, appelé pendant `create_card`, la rattache au lieu de
    # créer une organisation en double (D-CRM-005).
    @@converting = {} of UInt64 => Int64
    @@mutex = Mutex.new

    def self.converting : Int64?
      @@mutex.synchronize { @@converting[Fiber.current.object_id]? }
    end

    # « Devenir client » : crée la fiche client du cœur à partir de
    # l'organisation (nom, SIREN, TVA, courriel, téléphone, adresse, nature),
    # puis l'y rattache. Rend les erreurs du cœur telles quelles.
    def self.become_customer!(actor : Partiduo::Api::Actor, row : Organization,
                              input : Api::CustomerInput) : Array(FieldError)
      return [Records.error(FieldError::BASE, "organization.already_customer")] if row.card_id
      unless Api::NATURES.includes?(input.nature)
        return [Records.error("nature", "organization.nature.invalid", {"value" => input.nature})]
      end
      category_id = input.category_id || default_category(actor)
      return [Records.error("category_id", "organization.category_id.missing")] if category_id.nil?

      address = Cards::AddressInput.new(line1: row.line1.to_s.presence, postcode: row.postcode.to_s.presence,
        city: row.city.to_s.presence, country_code: row.country_code.to_s.presence)
      card_input = Cards::CardInput.new(category_id: category_id, name: row.name.to_s, siren: row.siren.to_s.presence,
        vat_number: row.vat_number.to_s.presence, email: row.email.to_s.presence, phone: row.phone.to_s.presence,
        address: address, customer_nature: input.nature)
      key = Fiber.current.object_id
      @@mutex.synchronize { @@converting[key] = row.id!.to_i64 }
      result = begin
        Cards.create_card(actor, card_input)
      ensure
        @@mutex.synchronize { @@converting.delete(key) }
      end
      return result.errors if result.failure?

      card = result.value!
      if card.kind != "customer"
        return [Records.error("category_id", "organization.category_id.not_customer")]
      end
      # L'abonné de `card.saved` a pu déjà rattacher la fiche : on relit.
      fresh = Records.organization!(row.id!.to_i64, lock: true)
      fresh.card_id = card.id
      fresh.nature = input.nature
      fresh.save!
      [] of FieldError
    end

    # Catégorie `CUSTOMER`, à défaut la première catégorie de clients.
    def self.default_category(actor : Partiduo::Api::Actor) : Int64?
      (Cards.category_by_code(actor, "CUSTOMER") || Cards.categories(actor, "customer").first?).try(&.id)
    end

    # « Créer un devis » (ADR-009 D5) : l'organisation devient d'abord
    # cliente si elle est prospect, puis un devis brouillon est créé et lié ;
    # l'opportunité passe à « Proposition » si elle était avant. Rend le
    # devis ou les erreurs.
    def self.create_quote!(actor : Partiduo::Api::Actor, row : Opportunity) : Inv::DocumentView | Array(FieldError)
      stage = Records.stage!(row.stage_id!.to_i64)
      return [Records.error(FieldError::BASE, "opportunity.closed")] unless stage.kind == "open"
      organization = Records.organization!(row.organization_id!.to_i64, lock: true)
      unless organization.card_id
        errors = become_customer!(actor, organization, Api::CustomerInput.new(nature: organization.nature.to_s))
        return errors unless errors.empty?
        organization = Records.organization!(organization.id!.to_i64)
      end
      card_id = organization.card_id.try(&.to_i64) || raise "crm : organisation sans fiche après conversion"

      lines = [Inv::LineInput.new(kind: "note", description: row.title.to_s)]
      result = Inv.create_document(actor, Inv::DocumentInput.new(kind: "quote", customer_card_id: card_id, lines: lines))
      return result.errors if result.failure?
      document = result.value!
      DocumentLink.create!(opportunity_id: row.id, document_id: document.id, kind: "quote", created_by_id: actor.user_id,
        created_at: Time.utc)
      if (proposal = Pipeline.proposal_stage) && Pipeline.before?(row, proposal)
        Pipeline.move!(row, proposal, actor.user_id, "quote_created")
      else
        row.save!
      end
      document
    end
  end
end
