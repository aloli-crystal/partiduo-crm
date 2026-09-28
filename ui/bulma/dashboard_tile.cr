# SPDX-License-Identifier: AGPL-3.0-or-later

module Crm
  module Ui
    # Tuile « Commercial » du tableau de bord du dossier (ADR-009 D6) :
    # pipeline pondéré, opportunités ouvertes, activités en retard, lus par
    # `Crm::Api.tile` (rien si l'extension est inactive ou l'acteur sans
    # droit).
    module Tile
      def self.for(actor : Partiduo::Api::Actor, fmt : PartiduoUi::Format) : PartiduoUi::Dashboard::Tile?
        view = Api.tile(actor) || return
        late = view.late_activities
        PartiduoUi::Dashboard::Tile.new(Crm::CODE, I18n.t("crm_ui.tile.label"), fmt.amount(view.weighted_amount),
          sub: I18n.t("crm_ui.tile.sub", count: view.open_count),
          alert: late.zero? ? nil : I18n.t("crm_ui.tile.late", count: late), url: Ui.url("pipeline"))
      end
    end
  end
end

# L'interface commune n'offre pas encore aux extensions de point
# d'accroche pour une tuile du tableau de bord (seulement un compteur de
# menu et une ligne de « À traiter ») : la tuile est ajoutée en complétant
# la construction du tableau de bord, sans modifier `partiduo-ui-bulma`
# (BLOCAGES B-CRM-001, à remplacer par le point d'accroche quand il existera).
module PartiduoUi
  class Dashboard
    def build : self
      previous_def
      Crm::Ui::Tile.for(@actor, @fmt).try { |tile| tiles << tile }
      self
    end
  end
end
