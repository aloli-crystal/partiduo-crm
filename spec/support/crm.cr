# SPDX-License-Identifier: AGPL-3.0-or-later

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration. Sans ligne dans `modules_activation`, c'est
# l'ensemble actif de l'instance (DECISIONS D-018 du cœur).
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

module Crm
  # Outils des specs : dossier provisionné par le contrat du cœur,
  # extension activée, acteurs, organisations, contacts, opportunités.
  module SpecSupport
    alias Api = Crm::Api
    alias Inv = Partiduo::Api::Invoicing

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    def self.today : Time
      Partiduo::Api::Core.today
    end

    # Dossier FR (société, TVA, catégories de fiches, exercice 2026), utilisateurs de test
    # (identifiants 1 et 2 : responsables possibles), extension active.
    def self.setup : Nil
      PartiduoUi::Reference.provision
      PartiduoUi::Reference.fiscal_year(2026)
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
      activate
    end

    # Active l'extension. Les tables sont vidées entre les exemples : les
    # valeurs initiales posées par la migration sont remises comme au
    # provisionnement (`Crm::Defaults`).
    def self.activate : Nil
      Partiduo::Api::Modules.activate(system, Crm::CODE).value!
      Crm::Defaults.ensure!
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    # Acteur commercial complet : relation client, fiches, Facturation.
    def self.seller(email : String = "alice@example.com") : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), [Api::READ, Api::WRITE, "cards.card.read", "cards.card.write",
                                                 Inv::READ, Inv::WRITE, Inv::ISSUE, "vat.rate.read"])
    end

    def self.admin : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id("alice@example.com"), [Api::READ, Api::WRITE, Api::ADMIN, "cards.card.read",
                                                               "cards.card.write", Inv::READ, Inv::WRITE, Inv::ISSUE])
    end

    def self.reader : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id("bruno@example.com"), [Api::READ])
    end

    def self.writer : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id("bruno@example.com"), [Api::READ, Api::WRITE])
    end

    def self.organization(name : String = "Menuiserie Leroux", **options) : Api::OrganizationView
      Api.create_organization(seller, Api::OrganizationInput.new(**options.merge(name: name))).value!
    end

    def self.contact(last_name : String = "Leroux", organization_id : Int64? = nil, **options) : Api::ContactView
      Api.create_contact(seller, Api::ContactInput.new(**options.merge(last_name: last_name, organization_id: organization_id))).value!
    end

    def self.opportunity(title : String = "Agencement boutique", organization_id : Int64? = nil,
                         amount : String = "12000", **options) : Api::OpportunityView
      organization_id ||= organization.id
      Api.create_opportunity(seller, Api::OpportunityInput.new(**options.merge(title: title,
        organization_id: organization_id, amount: d(amount)))).value!
    end

    def self.stage(code : String) : Api::StageView
      Api.stages(system).find! { |stage| stage.code == code }
    end

    def self.reason(code : String) : Api::ChoiceView
      Api.loss_reasons(system).find! { |reason| reason.code == code }
    end

    def self.source(code : String) : Api::ChoiceView
      Api.sources(system).find! { |source| source.code == code }
    end

    # Taux normal de TVA du dossier.
    def self.standard_rate : Partiduo::Api::Vat::RateView
      Partiduo::Api::Vat.rates(system).select { |rate| rate.category == "S" && !rate.reverse_charge }.max_by(&.rate)
    end

    # Complète le devis brouillon de l'opportunité (une ligne chiffrée) puis
    # l'émet : il est alors « envoyé », prêt pour la décision du client.
    def self.issue_quote(quote : Inv::DocumentView, amount : String = "12000") : Inv::DocumentView
      lines = [Inv::LineInput.new(kind: "free", description: "Agencement", quantity: d("1"), unit_price: d(amount),
        vat_rate_id: standard_rate.id)]
      input = Inv::DocumentInput.new(kind: "quote", customer_card_id: quote.customer_card_id, lines: lines,
        validity_date: date("2099-01-01"))
      Inv.update_document(system, quote.id, input).value!
      Inv.issue(system, quote.id).value!
    end

    # Événements `name` publiés pendant le bloc (abonné temporaire du socle).
    def self.capture(name : String, & : Array(Partiduo::Events::Event) ->) : Nil
      received = [] of Partiduo::Events::Event
      manifest = Partiduo::Modules["CORE"]
      previous = manifest.subscriptions[name]?.try(&.dup)
      manifest.on(name) { |event| received << event }
      begin
        yield received
      ensure
        if previous
          manifest.subscriptions[name] = previous
        else
          manifest.subscriptions.delete(name)
        end
      end
    end
  end
end
