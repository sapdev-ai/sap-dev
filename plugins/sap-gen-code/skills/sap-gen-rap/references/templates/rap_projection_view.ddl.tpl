@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: '%%LABEL%%'
@Metadata.allowExtensions: true
@Search.searchable: true
define view entity %%PROJ_VIEW%%
  as projection on %%ROOT_VIEW%%
{
%%PROJ_FIELDS%%
}
