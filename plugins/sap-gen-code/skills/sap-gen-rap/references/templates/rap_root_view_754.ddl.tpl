@AbapCatalog.sqlViewName: '%%SQL_VIEW%%'
@AbapCatalog.compiler.compareFilter: true
@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: '%%LABEL%%'
define root view %%ROOT_VIEW%%
  as select from %%TABLE%%
{
%%ROOT_FIELDS%%
}
