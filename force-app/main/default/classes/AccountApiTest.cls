@IsTest
private class AccountApiTest {
    @IsTest
    static void returnsMatchingAccounts() {
        insert new Account(Name = 'OSS LWC Test Account');

        RestRequest request = new RestRequest();
        request.params.put('search', 'OSS LWC');
        request.params.put('limit', '10');
        RestContext.request = request;
        RestContext.response = new RestResponse();

        Test.startTest();
        List<AccountApi.AccountResponse> results = AccountApi.getAccounts();
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected one matching account');
        System.assertEquals('OSS LWC Test Account', results[0].name);
    }

    @IsTest
    static void invalidLimitUsesDefault() {
        insert new Account(Name = 'Default Limit Account');

        RestRequest request = new RestRequest();
        request.params.put('limit', 'not-a-number');
        RestContext.request = request;
        RestContext.response = new RestResponse();

        Test.startTest();
        List<AccountApi.AccountResponse> results = AccountApi.getAccounts();
        Test.stopTest();

        System.assert(results.size() >= 1, 'Expected the default account query to return data');
    }
}
